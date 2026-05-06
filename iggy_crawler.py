"""
iggy_crawler.py — IGGY's self-directed web crawler
────────────────────────────────────────────────────
• Uses duckduckgo-search package (no API key, no brittle HTML selectors)
• Self-directed: derives topics from memory + domains_clean.csv + conversations
• Falls back to Playwright for JS-heavy pages
• Runs continuously; pass --crawl "topic" to force a one-off seed crawl

Install:
    pip install duckduckgo-search playwright requests beautifulsoup4 lxml
    playwright install chromium
"""

import asyncio
import sys
import os
import csv
import json
import time
import hashlib
import random
import argparse
import re
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional

# ── deps ──────────────────────────────────────────────────────────────────────
try:
    from duckduckgo_search import DDGS
except ImportError:
    print("⚠  Run: pip install duckduckgo-search")
    sys.exit(1)

try:
    import requests
    from bs4 import BeautifulSoup
except ImportError:
    print("⚠  Run: pip install requests beautifulsoup4 lxml")
    sys.exit(1)

try:
    from playwright.async_api import async_playwright
    PLAYWRIGHT_OK = True
except ImportError:
    PLAYWRIGHT_OK = False

# Memory module lives in same folder
sys.path.insert(0, str(Path(__file__).parent))
try:
    from iggy_memory import IggyMemory
    mem = IggyMemory()
except Exception as e:
    print(f"[Crawler] ⚠  Could not load IggyMemory: {e}")
    mem = None

# ── paths ─────────────────────────────────────────────────────────────────────
BASE_DIR        = Path(__file__).parent
DOMAINS_CSV     = BASE_DIR / "domains_clean.csv"
KNOWLEDGE_CSV   = BASE_DIR / "iggy_global_knowledge.csv"
CRAWL_LOG       = BASE_DIR / "iggy_crawl_log.txt"
CRAWLED_CACHE   = BASE_DIR / "iggy_crawled_urls.json"   # dedup cache

# ── defaults ──────────────────────────────────────────────────────────────────
CRAWL_INTERVAL_SEC  = 120        # seconds between autonomous crawl cycles
MAX_PAGES_PER_CYCLE = 8          # pages fetched per cycle
MAX_LINKS_PER_PAGE  = 3          # deep links followed per page
CHUNK_SIZE          = 400        # words per memory chunk
MIN_CHUNK_WORDS     = 40         # discard very short chunks
REQUEST_TIMEOUT     = 12         # seconds
USER_AGENTS = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
    "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
]

# ── dedup cache ───────────────────────────────────────────────────────────────
def _load_crawled() -> set:
    if CRAWLED_CACHE.exists():
        try:
            return set(json.loads(CRAWLED_CACHE.read_text()))
        except Exception:
            pass
    return set()

def _save_crawled(seen: set):
    # Keep last 5000 URLs
    lst = list(seen)[-5000:]
    CRAWLED_CACHE.write_text(json.dumps(lst))

CRAWLED_URLS: set = _load_crawled()

# ── logging ───────────────────────────────────────────────────────────────────
def clog(msg: str):
    ts  = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}][Crawler] {msg}"
    print(line)
    with open(CRAWL_LOG, "a", encoding="utf-8") as f:
        f.write(line + "\n")

# ── topic derivation (self-directed) ─────────────────────────────────────────
FALLBACK_TOPICS = [
    "quantitative trading strategies",
    "crypto market microstructure",
    "algorithmic trading Python Julia",
    "machine learning finance",
    "reinforcement learning trading",
    "Binance futures API trading",
    "EMA MACD momentum strategy",
    "risk management position sizing",
    "neural networks time series prediction",
    "autonomous AI agent architecture",
]

def _topics_from_domains_csv() -> list:
    topics = []
    if not DOMAINS_CSV.exists():
        return topics
    try:
        with open(DOMAINS_CSV, newline="", encoding="utf-8") as f:
            for row in csv.reader(f):
                if row:
                    val = row[0].strip()
                    if val and not val.lower().startswith("domain"):
                        # turn domain name into search phrase
                        phrase = val.replace("-", " ").replace(".", " ").strip()
                        if phrase:
                            topics.append(phrase)
    except Exception:
        pass
    return topics

def _topics_from_knowledge_csv() -> list:
    """Mine recent entries in iggy_global_knowledge.csv for gap topics."""
    topics = []
    if not KNOWLEDGE_CSV.exists():
        return topics
    try:
        entries = []
        with open(KNOWLEDGE_CSV, newline="", encoding="utf-8") as f:
            for row in csv.reader(f):
                if len(row) >= 2:
                    entries.append(row[1])   # assumption: col 1 = topic/text
        # Take last 20, extract 2-4 word phrases as follow-up searches
        for entry in entries[-20:]:
            words = entry.split()[:6]
            if len(words) >= 3:
                topics.append(" ".join(words[:4]))
    except Exception:
        pass
    return topics

def _topics_from_memory() -> list:
    """Ask memory for the least-covered topics."""
    if mem is None:
        return []
    try:
        stats = mem.get_stats()
        # If memory is sparse, seed with fundamentals
        if stats.get("knowledge_chunks", 0) < 50:
            return ["quantitative trading fundamentals", "crypto technical analysis",
                    "algorithmic trading systems"]
    except Exception:
        pass
    return []

def derive_topics() -> list:
    """Compose a prioritised topic list without requiring user input."""
    topics: list = []
    topics.extend(_topics_from_memory())
    topics.extend(_topics_from_domains_csv())
    topics.extend(_topics_from_knowledge_csv())
    # Deduplicate while preserving order
    seen = set()
    deduped = []
    for t in topics:
        key = t.lower()[:60]
        if key not in seen:
            seen.add(key)
            deduped.append(t)
    # Always include fallbacks at the end
    for t in FALLBACK_TOPICS:
        key = t.lower()[:60]
        if key not in seen:
            seen.add(key)
            deduped.append(t)
    return deduped

# ── DuckDuckGo search (robust) ────────────────────────────────────────────────
def ddg_search(query: str, max_results: int = 5) -> list[dict]:
    """Return list of {title, url, body} dicts. Never raises."""
    try:
        with DDGS() as ddgs:
            results = list(ddgs.text(query, max_results=max_results))
        clog(f"DDG '{query}' → {len(results)} results")
        return results
    except Exception as e:
        clog(f"DDG error for '{query}': {e}")
        return []

# ── HTML fetch (requests + fallback playwright) ───────────────────────────────
def _fetch_html_requests(url: str) -> Optional[str]:
    headers = {"User-Agent": random.choice(USER_AGENTS)}
    try:
        r = requests.get(url, headers=headers, timeout=REQUEST_TIMEOUT, allow_redirects=True)
        if r.status_code == 200 and "text/html" in r.headers.get("Content-Type", ""):
            return r.text
    except Exception:
        pass
    return None

async def _fetch_html_playwright(url: str) -> Optional[str]:
    if not PLAYWRIGHT_OK:
        return None
    try:
        async with async_playwright() as p:
            browser = await p.chromium.launch(headless=True)
            page = await browser.new_page()
            await page.goto(url, timeout=15_000, wait_until="domcontentloaded")
            content = await page.content()
            await browser.close()
            return content
    except Exception:
        return None

def fetch_page(url: str) -> Optional[str]:
    html = _fetch_html_requests(url)
    if html:
        return html
    # Playwright fallback for JS-heavy pages
    if PLAYWRIGHT_OK:
        return asyncio.run(_fetch_html_playwright(url))
    return None

# ── text extraction & chunking ────────────────────────────────────────────────
def extract_text(html: str) -> str:
    soup = BeautifulSoup(html, "lxml")
    for tag in soup(["script", "style", "nav", "footer", "header", "aside"]):
        tag.decompose()
    return " ".join(soup.get_text(separator=" ").split())

def chunk_text(text: str, source: str, topic: str) -> list[dict]:
    words = text.split()
    chunks = []
    for i in range(0, len(words), CHUNK_SIZE):
        window = words[i : i + CHUNK_SIZE]
        if len(window) < MIN_CHUNK_WORDS:
            continue
        chunk_text_str = " ".join(window)
        uid = hashlib.md5(chunk_text_str[:80].encode()).hexdigest()[:12]
        chunks.append({
            "id":     uid,
            "text":   chunk_text_str,
            "source": source,
            "topic":  topic,
            "ts":     datetime.now().isoformat(),
        })
    return chunks

def extract_links(html: str, base_url: str) -> list[str]:
    soup = BeautifulSoup(html, "lxml")
    links = []
    base_domain = re.sub(r"(https?://[^/]+).*", r"\1", base_url)
    for a in soup.find_all("a", href=True):
        href = a["href"].strip()
        if href.startswith("http"):
            links.append(href)
        elif href.startswith("/"):
            links.append(base_domain + href)
    # Deduplicate, exclude social / ad domains
    bad = {"twitter.com", "facebook.com", "instagram.com", "reddit.com",
           "youtube.com", "tiktok.com", "linkedin.com", "ads.", "doubleclick"}
    clean = []
    seen = set()
    for l in links:
        if any(b in l for b in bad):
            continue
        if l not in seen and l not in CRAWLED_URLS:
            seen.add(l)
            clean.append(l)
    return clean[:MAX_LINKS_PER_PAGE * 4]   # oversample, pick best later

# ── store chunks ──────────────────────────────────────────────────────────────
def store_chunks(chunks: list[dict]) -> int:
    if not chunks:
        return 0
    stored = 0
    for chunk in chunks:
        try:
            if mem:
                mem.store_knowledge(chunk["text"], metadata={
                    "source": chunk["source"],
                    "topic":  chunk["topic"],
                    "ts":     chunk["ts"],
                })
            stored += 1
        except Exception as e:
            clog(f"Store error: {e}")
    return stored

# ── single URL crawl ──────────────────────────────────────────────────────────
def crawl_url(url: str, topic: str, follow_links: bool = True) -> int:
    """Fetch a URL, chunk it, store in memory. Returns chunks stored."""
    if url in CRAWLED_URLS:
        return 0
    CRAWLED_URLS.add(url)

    html = fetch_page(url)
    if not html:
        clog(f"  ✗ Could not fetch {url}")
        return 0

    text = extract_text(html)
    if len(text.split()) < MIN_CHUNK_WORDS:
        clog(f"  ✗ Too little text at {url}")
        return 0

    chunks = chunk_text(text, source=url, topic=topic)
    n = store_chunks(chunks)
    clog(f"  ✓ {url} → {n} chunks stored (topic: {topic})")

    # Follow internal links (depth-1 only)
    total = n
    if follow_links and n > 0:
        links = extract_links(html, url)
        random.shuffle(links)
        for link in links[:MAX_LINKS_PER_PAGE]:
            if link not in CRAWLED_URLS:
                time.sleep(0.8)
                total += crawl_url(link, topic, follow_links=False)

    return total

# ── one crawl cycle ───────────────────────────────────────────────────────────
def crawl_cycle(force_topic: Optional[str] = None) -> dict:
    topics = [force_topic] if force_topic else derive_topics()
    random.shuffle(topics)

    pages_done = 0
    total_chunks = 0

    for topic in topics:
        if pages_done >= MAX_PAGES_PER_CYCLE:
            break

        results = ddg_search(topic, max_results=4)
        if not results:
            continue

        for r in results:
            if pages_done >= MAX_PAGES_PER_CYCLE:
                break
            url = r.get("href") or r.get("url", "")
            if not url:
                continue
            # Also store the DDG snippet itself as a lightweight chunk
            snippet = r.get("body", "")
            if snippet and len(snippet.split()) >= MIN_CHUNK_WORDS:
                mini_chunks = chunk_text(snippet, source=url, topic=topic)
                total_chunks += store_chunks(mini_chunks)

            total_chunks += crawl_url(url, topic)
            pages_done += 1
            time.sleep(1.0 + random.random())

    _save_crawled(CRAWLED_URLS)
    stats = mem.get_stats() if mem else {}
    clog(f"Cycle done | pages:{pages_done} chunks_added:{total_chunks} memory:{stats}")
    return {"pages": pages_done, "chunks": total_chunks, "memory": stats}

# ── continuous daemon ─────────────────────────────────────────────────────────
def run_continuous():
    clog("🕷  IGGY crawler daemon started (self-directed mode)")
    while True:
        try:
            crawl_cycle()
        except KeyboardInterrupt:
            clog("Crawler stopped by user.")
            break
        except Exception as e:
            clog(f"Cycle error: {e}")
        clog(f"⏳ Sleeping {CRAWL_INTERVAL_SEC}s before next cycle…")
        time.sleep(CRAWL_INTERVAL_SEC)

# ── entry point ───────────────────────────────────────────────────────────────
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="IGGY web crawler")
    parser.add_argument("--crawl", type=str, default="",
                        help="One-off topic to crawl, then exit")
    parser.add_argument("--daemon", action="store_true",
                        help="Run continuously (default if no --crawl given)")
    args = parser.parse_args()

    if args.crawl:
        result = crawl_cycle(force_topic=args.crawl)
        print(f"Done. Memory: {result['memory']}")
    else:
        run_continuous()
