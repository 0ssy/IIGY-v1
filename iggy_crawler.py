"""
iggy_crawler.py — IGGY's self-directed web crawler  (v2)
─────────────────────────────────────────────────────────
Fixes vs v1:
  • Uses `ddgs` package (duckduckgo_search was renamed — pip install ddgs)
  • store_knowledge() called with positional text only; source/topic stored
    via ChromaDB metadata through a safe wrapper that handles any signature
  • get_stats() fallback added for IggyMemory objects that don't expose it
  • Per-search sleep added to avoid DDG rate-limiting (was causing 0 results)

Install / upgrade:
    pip install ddgs playwright requests beautifulsoup4 lxml
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
import inspect
from datetime import datetime
from pathlib import Path
from typing import Optional

# ── ddgs (renamed from duckduckgo_search) ────────────────────────────────────
try:
    from ddgs import DDGS
except ImportError:
    try:                                   # fallback: old name still installed
        from duckduckgo_search import DDGS
        import warnings
        warnings.filterwarnings("ignore", category=RuntimeWarning)
    except ImportError:
        print("⚠  Run: pip install ddgs")
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

# ── IggyMemory (safe loader) ──────────────────────────────────────────────────
sys.path.insert(0, str(Path(__file__).parent))
mem = None
_mem_store_sig = None   # will be inspected once

def _load_memory():
    global mem, _mem_store_sig
    try:
        from iggy_memory import IggyMemory
        mem = IggyMemory()
        # Inspect the actual store_knowledge signature once
        sig = inspect.signature(mem.store_knowledge)
        _mem_store_sig = list(sig.parameters.keys())
        print(f"[Crawler] store_knowledge params: {_mem_store_sig}")
    except Exception as e:
        print(f"[Crawler] ⚠  Could not load IggyMemory: {e}")
        mem = None

_load_memory()

def _mem_store(text: str, source: str = "", topic: str = "") -> bool:
    """Call store_knowledge however this version of IggyMemory expects it."""
    if mem is None:
        return False
    try:
        params = _mem_store_sig or []
        if "metadata" in params:
            mem.store_knowledge(text, metadata={"source": source, "topic": topic})
        elif "source" in params and "topic" in params:
            mem.store_knowledge(text, source=source, topic=topic)
        elif "source" in params:
            mem.store_knowledge(text, source=source)
        else:
            mem.store_knowledge(text)
        return True
    except Exception as e:
        clog(f"Store error: {e}")
        return False

def _mem_stats() -> dict:
    if mem is None:
        return {}
    try:
        if hasattr(mem, "get_stats"):
            return mem.get_stats()
        # Fallback: read ChromaDB counts directly
        stats = {}
        if hasattr(mem, "knowledge_collection"):
            stats["knowledge_chunks"] = mem.knowledge_collection.count()
        if hasattr(mem, "conv_collection"):
            stats["conversations"] = mem.conv_collection.count()
        return stats
    except Exception:
        return {}

# ── paths ─────────────────────────────────────────────────────────────────────
BASE_DIR      = Path(__file__).parent
DOMAINS_CSV   = BASE_DIR / "domains_clean.csv"
KNOWLEDGE_CSV = BASE_DIR / "iggy_global_knowledge.csv"
CRAWL_LOG     = BASE_DIR / "iggy_crawl_log.txt"
CRAWLED_CACHE = BASE_DIR / "iggy_crawled_urls.json"

# ── config ────────────────────────────────────────────────────────────────────
CRAWL_INTERVAL_SEC  = 180        # seconds between autonomous cycles
MAX_PAGES_PER_CYCLE = 6          # pages to fetch per cycle
MAX_LINKS_PER_PAGE  = 2          # deep links to follow per page
CHUNK_SIZE          = 400        # words per memory chunk
MIN_CHUNK_WORDS     = 40
REQUEST_TIMEOUT     = 12
DDG_SLEEP_MIN       = 2.5        # min seconds between DDG queries (rate limit)
DDG_SLEEP_MAX       = 5.0        # max seconds between DDG queries

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
    CRAWLED_CACHE.write_text(json.dumps(list(seen)[-5000:]))

CRAWLED_URLS: set = _load_crawled()

# ── logging ───────────────────────────────────────────────────────────────────
def clog(msg: str):
    ts   = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}][Crawler] {msg}"
    print(line)
    try:
        with open(CRAWL_LOG, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass

# ── topic derivation ──────────────────────────────────────────────────────────
FALLBACK_TOPICS = [
    "quantitative trading strategies",
    "crypto technical analysis indicators",
    "algorithmic trading Python Julia",
    "machine learning finance applications",
    "reinforcement learning trading systems",
    "Binance futures API guide",
    "EMA MACD momentum trading",
    "risk management position sizing",
    "neural networks time series forecasting",
    "autonomous AI agent architecture design",
    "WebSocket real-time data processing",
    "crypto market microstructure",
    "personal AI assistant development",
    "continuous learning AI systems",
    "RAG retrieval augmented generation",
]

def _topics_from_domains_csv() -> list:
    topics = []
    if not DOMAINS_CSV.exists():
        return topics
    try:
        with open(DOMAINS_CSV, newline="", encoding="utf-8") as f:
            for row in csv.reader(f):
                if row:
                    val    = row[0].strip()
                    phrase = val.replace("-", " ").replace(".", " ").strip()
                    if phrase and not phrase.lower().startswith("domain"):
                        topics.append(phrase)
    except Exception:
        pass
    return topics

def _topics_from_knowledge_csv() -> list:
    topics = []
    if not KNOWLEDGE_CSV.exists():
        return topics
    try:
        entries = []
        with open(KNOWLEDGE_CSV, newline="", encoding="utf-8") as f:
            for row in csv.reader(f):
                if len(row) >= 2:
                    entries.append(row[1])
        for entry in entries[-20:]:
            words = entry.split()[:6]
            if len(words) >= 3:
                topics.append(" ".join(words[:4]))
    except Exception:
        pass
    return topics

def derive_topics() -> list:
    topics: list = []
    stats = _mem_stats()
    if stats.get("knowledge_chunks", 0) < 50:
        topics += ["quantitative trading fundamentals",
                   "crypto technical analysis",
                   "algorithmic trading systems Julia"]
    topics += _topics_from_domains_csv()
    topics += _topics_from_knowledge_csv()
    seen   = set()
    result = []
    for t in topics + FALLBACK_TOPICS:
        key = t.lower()[:60]
        if key not in seen:
            seen.add(key)
            result.append(t)
    return result

# ── DDG search (with rate-limit sleep) ───────────────────────────────────────
def ddg_search(query: str, max_results: int = 5) -> list:
    """Returns list of result dicts. Sleeps before each call to avoid rate limits."""
    sleep_t = random.uniform(DDG_SLEEP_MIN, DDG_SLEEP_MAX)
    time.sleep(sleep_t)
    try:
        with DDGS() as ddgs:
            results = list(ddgs.text(query, max_results=max_results))
        clog(f"DDG '{query}' → {len(results)} results")
        return results
    except Exception as e:
        clog(f"DDG error for '{query}': {e}")
        return []

# ── HTML fetching ─────────────────────────────────────────────────────────────
def _fetch_html_requests(url: str) -> Optional[str]:
    headers = {"User-Agent": random.choice(USER_AGENTS)}
    try:
        r = requests.get(url, headers=headers,
                         timeout=REQUEST_TIMEOUT, allow_redirects=True)
        if r.status_code == 200 and "text/html" in r.headers.get("Content-Type", ""):
            return r.text
    except Exception:
        pass
    return None

async def _fetch_html_playwright_async(url: str) -> Optional[str]:
    try:
        async with async_playwright() as p:
            browser = await p.chromium.launch(headless=True)
            page    = await browser.new_page()
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
    if PLAYWRIGHT_OK:
        try:
            return asyncio.run(_fetch_html_playwright_async(url))
        except Exception:
            pass
    return None

# ── text extraction & chunking ────────────────────────────────────────────────
def extract_text(html: str) -> str:
    soup = BeautifulSoup(html, "lxml")
    for tag in soup(["script", "style", "nav", "footer", "header", "aside"]):
        tag.decompose()
    return " ".join(soup.get_text(separator=" ").split())

def chunk_text(text: str, source: str, topic: str) -> list:
    words  = text.split()
    chunks = []
    for i in range(0, len(words), CHUNK_SIZE):
        window = words[i: i + CHUNK_SIZE]
        if len(window) < MIN_CHUNK_WORDS:
            continue
        chunks.append({
            "text":   " ".join(window),
            "source": source,
            "topic":  topic,
        })
    return chunks

def extract_links(html: str, base_url: str) -> list:
    soup   = BeautifulSoup(html, "lxml")
    base   = re.sub(r"(https?://[^/]+).*", r"\1", base_url)
    bad    = {"twitter.com", "facebook.com", "instagram.com", "reddit.com",
              "youtube.com", "tiktok.com", "linkedin.com", "doubleclick",
              "zhihu.com"}   # zhihu blocks requests
    links  = []
    seen   = set()
    for a in soup.find_all("a", href=True):
        href = a["href"].strip()
        if href.startswith("/"):
            href = base + href
        if not href.startswith("http"):
            continue
        if any(b in href for b in bad):
            continue
        if href not in seen and href not in CRAWLED_URLS:
            seen.add(href)
            links.append(href)
    return links[: MAX_LINKS_PER_PAGE * 4]

# ── store ─────────────────────────────────────────────────────────────────────
def store_chunks(chunks: list) -> int:
    stored = 0
    for chunk in chunks:
        if _mem_store(chunk["text"], chunk["source"], chunk["topic"]):
            stored += 1
    return stored

# ── crawl one URL ─────────────────────────────────────────────────────────────
def crawl_url(url: str, topic: str, follow_links: bool = True) -> int:
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
    n      = store_chunks(chunks)
    clog(f"  ✓ {url} → {n} chunks (topic: {topic})")

    if follow_links and n > 0:
        links = extract_links(html, url)
        random.shuffle(links)
        for link in links[:MAX_LINKS_PER_PAGE]:
            if link not in CRAWLED_URLS:
                time.sleep(0.8)
                crawl_url(link, topic, follow_links=False)

    return n

# ── one full cycle ────────────────────────────────────────────────────────────
def crawl_cycle(force_topic: Optional[str] = None) -> dict:
    topics     = [force_topic] if force_topic else derive_topics()
    random.shuffle(topics)

    pages_done   = 0
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

            # Store snippet directly (fast, no HTTP needed)
            snippet = r.get("body", "")
            if snippet and len(snippet.split()) >= MIN_CHUNK_WORDS:
                total_chunks += store_chunks(
                    chunk_text(snippet, source=url, topic=topic))

            total_chunks += crawl_url(url, topic)
            pages_done   += 1
            time.sleep(1.0 + random.random())

    _save_crawled(CRAWLED_URLS)
    stats = _mem_stats()
    clog(f"Cycle done | pages:{pages_done} chunks_added:{total_chunks} memory:{stats}")
    return {"pages": pages_done, "chunks": total_chunks, "memory": stats}

# ── daemon ────────────────────────────────────────────────────────────────────
def run_continuous():
    clog("🕷  IGGY crawler daemon — self-directed")
    while True:
        try:
            crawl_cycle()
        except KeyboardInterrupt:
            clog("Stopped.")
            break
        except Exception as e:
            clog(f"Cycle error: {e}")
        clog(f"⏳ Sleeping {CRAWL_INTERVAL_SEC}s…")
        time.sleep(CRAWL_INTERVAL_SEC)

# ── entry ─────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--crawl", type=str, default="",
                        help="Force a single topic then exit")
    args = parser.parse_args()

    if args.crawl:
        result = crawl_cycle(force_topic=args.crawl)
        print(f"Done. Memory: {result['memory']}")
    else:
        run_continuous()
