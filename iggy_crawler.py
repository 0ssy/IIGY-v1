"""
iggy_crawler.py — IGGY's eyes on the web.

Uses Playwright (real browser, handles JS sites) to crawl URLs.
Can use your saved Google/Edge browser profile so she's logged in
to sites you have access to.

Two modes:
  1. SEED mode   — you give it a list of URLs/topics to learn from
  2. SCOUT mode  — continuously searches for topics IGGY needs to know about

All text is stored in:
  - IggyMemory (ChromaDB) — for retrieval during conversations
  - iggy_train_queue.jsonl — for periodic fine-tuning
"""

import asyncio, json, re, time
from pathlib import Path
from datetime import datetime
from typing import List, Optional
from urllib.parse import urlparse, urljoin

from playwright.async_api import async_playwright, Browser, BrowserContext

# ── Config ────────────────────────────────────────────────────────────────────
TRAIN_QUEUE   = Path("iggy_train_queue.jsonl")
VISITED_LOG   = Path("iggy_visited_urls.txt")
CRAWL_TOPICS  = Path("iggy_crawl_topics.txt")   # one topic/URL per line

# Use your real browser profile so you're already logged in
# Edge:   C:/Users/<you>/AppData/Local/Microsoft/Edge/User Data
# Chrome: C:/Users/<you>/AppData/Local/Google/Chrome/User Data
EDGE_PROFILE   = None   # set to your Edge profile path to use cookies
CHROME_PROFILE = None   # set to your Chrome profile path

MAX_DEPTH     = 2        # how many links deep to follow
MAX_PER_CRAWL = 30       # max pages per crawl session
MIN_TEXT_LEN  = 200      # ignore pages with less text than this
CHUNK_SIZE    = 600      # characters per knowledge chunk
CRAWL_DELAY   = 1.5      # seconds between requests (be polite)

# Sites to always skip
SKIP_DOMAINS = {
    "facebook.com", "twitter.com", "instagram.com",
    "tiktok.com", "reddit.com",   # too noisy
}

# ── Cleaner ───────────────────────────────────────────────────────────────────
def clean_text(raw: str) -> str:
    """Strip boilerplate, normalize whitespace."""
    raw = re.sub(r'\s+', ' ', raw)
    raw = re.sub(r'(Cookie Policy|Privacy Policy|Terms of Service|Subscribe now)[^\n]*', '', raw, flags=re.IGNORECASE)
    return raw.strip()

def chunk_text(text: str, source: str, topic: str = "") -> List[dict]:
    """Split text into overlapping chunks for the memory store."""
    words = text.split()
    chunks = []
    step = CHUNK_SIZE // 2  # 50% overlap
    for i in range(0, len(words), step):
        chunk = " ".join(words[i:i + CHUNK_SIZE])
        if len(chunk) < MIN_TEXT_LEN:
            continue
        chunks.append({
            "text": chunk,
            "source": source,
            "topic": topic,
            "timestamp": datetime.utcnow().isoformat(),
        })
    return chunks

# ── IggyCrawler ────────────────────────────────────────────────────────────────
class IggyCrawler:
    def __init__(self, memory=None):
        """memory: IggyMemory instance (optional, but recommended)."""
        self.memory = memory
        self.visited = self._load_visited()
        TRAIN_QUEUE.parent.mkdir(exist_ok=True)

    def _load_visited(self) -> set:
        if VISITED_LOG.exists():
            return set(VISITED_LOG.read_text().splitlines())
        return set()

    def _mark_visited(self, url: str):
        self.visited.add(url)
        with VISITED_LOG.open("a") as f:
            f.write(url + "\n")

    def _should_skip(self, url: str) -> bool:
        try:
            domain = urlparse(url).netloc.lower().replace("www.", "")
            return domain in SKIP_DOMAINS or url in self.visited
        except:
            return True

    async def _get_context(self, playwright) -> BrowserContext:
        """Launch browser, optionally with your saved login profile."""
        launch_args = {"headless": True, "args": ["--no-sandbox"]}

        if EDGE_PROFILE:
            browser = await playwright.chromium.launch_persistent_context(
                EDGE_PROFILE,
                channel="msedge",
                headless=True,
            )
            return browser  # PersistentContext acts as both browser and context

        if CHROME_PROFILE:
            browser = await playwright.chromium.launch_persistent_context(
                CHROME_PROFILE,
                channel="chrome",
                headless=True,
            )
            return browser

        # Default: fresh browser, no login
        browser = await playwright.chromium.launch(**launch_args)
        return await browser.new_context(
            user_agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        )

    async def crawl_url(self, url: str, topic: str = "", depth: int = 0) -> List[dict]:
        """Crawl a single URL and return extracted chunks."""
        if self._should_skip(url) or depth > MAX_DEPTH:
            return []

        chunks = []
        async with async_playwright() as pw:
            ctx = await self._get_context(pw)
            page = await ctx.new_page()

            try:
                print(f"[Crawler] {'  ' * depth}→ {url}")
                await page.goto(url, timeout=15000, wait_until="domcontentloaded")
                await asyncio.sleep(CRAWL_DELAY)

                # Extract main text content
                raw = await page.evaluate("""
                    () => {
                        // Remove noise elements
                        ['nav','footer','header','aside','script','style',
                         '.ad','.cookie','.popup','[role=banner]'].forEach(sel => {
                            document.querySelectorAll(sel).forEach(el => el.remove());
                        });
                        return document.body?.innerText || '';
                    }
                """)

                text = clean_text(raw)
                if len(text) >= MIN_TEXT_LEN:
                    page_chunks = chunk_text(text, source=url, topic=topic)
                    chunks.extend(page_chunks)
                    self._mark_visited(url)

                    # Store in IGGY's memory
                    if self.memory:
                        for c in page_chunks:
                            self.memory.store_knowledge(c["text"], source=url, topic=topic)

                    # Queue for fine-tuning
                    self._queue_for_training(page_chunks)

                    print(f"[Crawler] ✅ {len(page_chunks)} chunks from {url}")

                # Follow links (depth-first, same domain)
                if depth < MAX_DEPTH:
                    links = await page.evaluate("""
                        () => Array.from(document.querySelectorAll('a[href]'))
                            .map(a => a.href)
                            .filter(h => h.startsWith('http'))
                            .slice(0, 10)
                    """)
                    base_domain = urlparse(url).netloc
                    for link in links[:5]:
                        if urlparse(link).netloc == base_domain and not self._should_skip(link):
                            sub = await self.crawl_url(link, topic, depth + 1)
                            chunks.extend(sub)

            except Exception as e:
                print(f"[Crawler] ⚠️ Error on {url}: {e}")
            finally:
                await page.close()
                if hasattr(ctx, 'close'):
                    await ctx.close()

        return chunks

    async def search_and_crawl(self, query: str, num_results: int = 5) -> List[dict]:
        """
        Search DuckDuckGo (no login needed) for a query and crawl the results.
        This is how IGGY autonomously expands her knowledge.
        """
        search_url = f"https://duckduckgo.com/html/?q={query.replace(' ', '+')}"
        chunks = []

        async with async_playwright() as pw:
            ctx = await self._get_context(pw)
            page = await ctx.new_page()
            try:
                await page.goto(search_url, timeout=15000)
                await asyncio.sleep(1.5)

                links = await page.evaluate("""
                    () => Array.from(document.querySelectorAll('.result__url, .result__a'))
                        .map(a => a.href || a.textContent)
                        .filter(h => h && h.startsWith('http'))
                        .slice(0, 8)
                """)
                await page.close()
                await ctx.close()

                print(f"[Crawler] Searching '{query}' → {len(links)} results")
                for link in links[:num_results]:
                    result = await self.crawl_url(link, topic=query)
                    chunks.extend(result)

            except Exception as e:
                print(f"[Crawler] Search error: {e}")

        return chunks

    def _queue_for_training(self, chunks: List[dict]):
        """Append chunks to the training queue for periodic LoRA fine-tuning."""
        with TRAIN_QUEUE.open("a") as f:
            for c in chunks:
                # Format as instruction-following text for the model
                entry = {
                    "text": (
                        f"<|system|>\n{c.get('topic', 'Knowledge')}</s>\n"
                        f"<|user|>\nWhat do you know about this?</s>\n"
                        f"<|assistant|>\n{c['text']}</s>"
                    )
                }
                f.write(json.dumps(entry) + "\n")

    # ── Continuous Discovery Loop ──────────────────────────────────────────────
    async def run_discovery_loop(self, interval_minutes: int = 30):
        """
        Continuously crawl topics from iggy_crawl_topics.txt.
        Add URLs or search queries to that file, one per line.
        IGGY will keep expanding her knowledge automatically.
        """
        print(f"[Crawler] Discovery loop started. Checking every {interval_minutes}min.")
        while True:
            if CRAWL_TOPICS.exists():
                topics = [t.strip() for t in CRAWL_TOPICS.read_text().splitlines() if t.strip()]
                for topic in topics:
                    if topic.startswith("http"):
                        await self.crawl_url(topic, topic=topic)
                    else:
                        await self.search_and_crawl(topic, num_results=3)
                    await asyncio.sleep(5)
            await asyncio.sleep(interval_minutes * 60)

# ── CLI entrypoint ─────────────────────────────────────────────────────────────
if __name__ == "__main__":
    import sys
    from iggy_memory import IggyMemory

    mem = IggyMemory()
    crawler = IggyCrawler(memory=mem)

    if len(sys.argv) > 1:
        query = " ".join(sys.argv[1:])
        if query.startswith("http"):
            asyncio.run(crawler.crawl_url(query))
        else:
            asyncio.run(crawler.search_and_crawl(query))
    else:
        # Start continuous discovery loop
        asyncio.run(crawler.run_discovery_loop())
