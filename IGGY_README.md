# IGGY v2 — Architecture & Setup Guide

## What This Is

IGGY is a local, continuously learning personal AI assistant.
No API keys. No Ollama. No cloud. Runs entirely on your machine.

```
Your Laptop
│
├── iggy_assistant.py        ← Start here. The main loop.
│   │
│   ├── iggy_brain.py        ← TinyLlama (local LLM, runs offline)
│   │     └── iggy_adapters/ ← LoRA weights grow as she learns
│   │
│   ├── iggy_memory.py       ← ChromaDB (her personal knowledge store)
│   │     └── iggy_memory_store/ ← persists on disk between sessions
│   │
│   ├── iggy_crawler.py      ← Playwright crawler (feeds her knowledge)
│   │     └── iggy_train_queue.jsonl ← raw learning data
│   │
│   ├── iggy_trainer.py      ← LoRA fine-tune scheduler (runs in background)
│   │
│   ├── iggy_screen.py       ← Screen OCR (she sees what you see)
│   │
│   └── iggy_python_bridge.jl← Julia trading system ↔ Python
│
└── [Your existing Julia trading system]
```

---

## How IGGY Learns (the real answer)

IGGY's intelligence has **two layers**:

### Layer 1: RAG (instant, every conversation)
- The crawler stores text in ChromaDB (her long-term memory)
- Before every reply, IGGY retrieves the most relevant chunks from that store
- She answers using **her own accumulated knowledge**, not a generic model
- This happens immediately — as soon as the crawler adds something, she knows it

### Layer 2: LoRA Fine-tuning (deep, every ~60 min)
- New crawled pages + conversation turns go into a training queue
- Every 60 minutes, if there are 30+ new samples, she fine-tunes her actual weights
- The LoRA adapter (in `iggy_adapters/`) grows and updates — this IS her brain changing
- Hot-reloaded while running, no restart needed

Both layers work **without any API key**. The base model (TinyLlama) downloads once from HuggingFace (free), then runs fully offline.

---

## Setup

### 1. Install Python dependencies
```bash
pip install -r requirements_iggy.txt
playwright install chromium
```

### 2. Install Tesseract (for screen reading)
- **Windows**: https://github.com/UB-Mannheim/tesseract/wiki
- **Linux**: `sudo apt install tesseract-ocr`
- **macOS**: `brew install tesseract`

### 3. (Optional) Point to your browser profile for logged-in crawling
Edit `iggy_crawler.py`, set either:
```python
EDGE_PROFILE   = r"C:\Users\YourName\AppData\Local\Microsoft\Edge\User Data"
# or
CHROME_PROFILE = r"C:\Users\YourName\AppData\Local\Google\Chrome\User Data"
```
This lets IGGY crawl sites you're already logged into.

### 4. Run IGGY
```bash
python iggy_assistant.py
```

First run downloads TinyLlama (~600MB). Subsequent starts are instant.

---

## Teaching IGGY Things

### Method 1: Chat commands
```
You > crawl bitcoin futures trading strategies
You > learn from https://www.investopedia.com/terms/a/algorithmictrading.asp
You > add topic technical analysis candlestick patterns
```

### Method 2: Edit iggy_crawl_topics.txt
Add one topic or URL per line. IGGY will auto-crawl them every 30 minutes.
```
python trading strategies
risk management in crypto
kenya stock exchange NSE
your favorite blog URL
```

### Method 3: Corrections
```
You > crawl [something wrong answer]
IGGY > [wrong answer]
You > correct: [the right answer]
```
Corrections get 6x training weight. She learns fast from mistakes.

### Method 4: Direct crawl command
```bash
python iggy_assistant.py --crawl "quantitative trading"
python iggy_assistant.py --crawl https://yourfavoritesite.com
```

---

## Julia Trading Integration

Add to your `iggy_executive.jl`:
```julia
include("iggy_python_bridge.jl")
using .IggyPythonBridge

# After a trade closes:
notify_trade("BTCUSDT", "long", 45230.0, 127.50)

# Ask IGGY for input:
advice = ask_iggy("Should I reduce position size given current volatility?")
println("IGGY says: $advice")

# Push status for 'trade status' command in chat:
push_status(capital.balance, capital.dd, length(positions))
```

---

## Screen Awareness

When screen awareness is ON, IGGY can see:
- What application you're using
- Text visible on screen (via OCR)
- Changes in real-time

Try:
```
You > what am I looking at?
You > suggest improvements for this code
You > what does this error mean?
```

Toggle: `screen on` / `screen off`

---

## Upgrading the Model

To use a smarter model, change `MODEL_NAME` in `iggy_brain.py`:

| Model | Size | RAM needed | Notes |
|-------|------|------------|-------|
| `TinyLlama/TinyLlama-1.1B-Chat-v1.0` | 600MB | 4GB | Default, CPU-friendly |
| `microsoft/phi-2` | 2.7B | 6GB | Much smarter, still CPU-ok |
| `mistralai/Mistral-7B-Instruct-v0.2` | 7B | 16GB | Best quality, needs more RAM |

All free to download from HuggingFace. No API key needed.

---

## File Map

| File | Purpose |
|------|---------|
| `iggy_assistant.py` | Main loop, command handler |
| `iggy_brain.py` | LLM inference + LoRA training |
| `iggy_memory.py` | ChromaDB vector store |
| `iggy_crawler.py` | Playwright web crawler |
| `iggy_trainer.py` | Background training scheduler |
| `iggy_screen.py` | Screen capture + OCR |
| `iggy_python_bridge.jl` | Julia ↔ Python socket bridge |
| `iggy_memory_store/` | ChromaDB persisted to disk |
| `iggy_adapters/` | LoRA fine-tune weights |
| `iggy_train_queue.jsonl` | Pending training data |
| `iggy_crawl_topics.txt` | Auto-crawl topic list |
| `iggy_visited_urls.txt` | Deduplication log |
