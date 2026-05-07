"""
iggy_vision.py
──────────────
IGGY's always-on eyes. Watches everything you do — not just trading.
Browsing, coding, reading, chatting, research, documents — all of it.

Runs in a background daemon thread. No files saved. No screenshots.
Detects what activity you're doing, extracts meaningful text,
and feeds it into IGGY's knowledge base continuously.

Install:
    pip install mss pillow pytesseract numpy pygetwindow
    Windows Tesseract: https://github.com/UB-Mannheim/tesseract/wiki
"""

import threading
import time
import re
import numpy as np
from datetime import datetime
from collections import deque
from PIL import Image
import pytesseract
import mss

# ── If Tesseract is not on PATH set full path here ─────────────────────────────
pytesseract.pytesseract.tesseract_cmd = r"C:\Program Files\Tesseract-OCR\tesseract.exe"

# ── Config ─────────────────────────────────────────────────────────────────────

CAPTURE_INTERVAL  = 1.2    # seconds between frames
CHANGE_THRESHOLD  = 0.018  # 1.8% pixel change triggers OCR
MIN_TEXT_LENGTH   = 25     # ignore near-empty OCR results
MAX_TEXT_LENGTH   = 3000   # truncate very long results
MONITOR_INDEX     = 1      # 1 = primary, 2 = secondary
IDLE_PAUSE        = 10.0   # slow down after N seconds of no change
IDLE_INTERVAL     = 3.0    # interval when idle
CONTEXT_WINDOW    = 6      # rolling window of recent activity

# ── Activity fingerprints ──────────────────────────────────────────────────────

ACTIVITY_PATTERNS = {
    "trading": [
        r"\b(buy|sell|long|short|pnl|profit|loss|position|entry|exit|stop.?loss)\b",
        r"\b(btc|eth|sol|usdt|binance|bybit|kraken|coinbase)\b",
        r"\b(chart|candle|macd|rsi|bollinger|ema|sma|indicator|orderbook)\b",
        r"\b(\d+\.\d{2,})\s*(usdt|usd|\$)",
    ],
    "browsing": [
        r"\b(http|www\.|\.com|\.org|\.io|search|google|youtube|reddit)\b",
        r"\b(back|forward|reload|bookmark|tab|browser)\b",
    ],
    "coding": [
        r"\b(def |function |class |import |return |const |let |var |elif )\b",
        r"(==|!=|<=|>=|=>|->|\.\.\.|::|##|//|\{\}|\[\])",
        r"\b(error|exception|traceback|syntax|compile|debug|terminal|powershell)\b",
        r"\b(git|commit|push|pull|branch|merge|diff)\b",
    ],
    "reading": [
        r"\b(article|chapter|introduction|conclusion|abstract|summary|overview)\b",
        r"\b(published|author|source|according to|research|study|report)\b",
        r"\b(paragraph|section|page \d+|continued|references)\b",
    ],
    "communication": [
        r"\b(message|reply|send|inbox|email|slack|discord|chat|dm|thread)\b",
        r"\b(dear |hi |hello |regards|sincerely|from:|to:|subject:|cc:)\b",
        r"\b(whatsapp|telegram|teams|zoom|meet|call|meeting)\b",
    ],
    "documents": [
        r"\b(page \d+|table of contents|figure \d+|section \d+|appendix)\b",
        r"\b(draft|edit|format|paragraph|heading|bullet|insert|word|excel)\b",
        r"\b(font|bold|italic|align|margin|column|row|cell|formula)\b",
    ],
    "media": [
        r"\b(playing|paused|volume|fullscreen|subtitles|episode|playlist)\b",
        r"\b(youtube|netflix|spotify|twitch|video|music|podcast|stream)\b",
    ],
    "research": [
        r"\b(wikipedia|wiki|definition|explain|how does|meaning)\b",
        r"\b(paper|arxiv|doi|citation|findings|methodology|hypothesis)\b",
        r"\b(search results|related|suggested|recommended|top results)\b",
    ],
    "system": [
        r"\b(task manager|cpu|memory|disk|processes|services|settings)\b",
        r"\b(install|update|download|progress|setup|wizard|driver)\b",
    ],
}

# ── State ──────────────────────────────────────────────────────────────────────

_running       = False
_thread        = None
_prev_frame    = None
_lock          = threading.Lock()
_on_change_cb  = None
_last_text     = ""
_last_activity = "unknown"
_activity_log  = deque(maxlen=CONTEXT_WINDOW)
_last_change_t = time.time()


# ── Activity detection ─────────────────────────────────────────────────────────

def detect_activity(text):
    text_lower = text.lower()
    scores = {}
    for activity, patterns in ACTIVITY_PATTERNS.items():
        score = sum(len(re.findall(p, text_lower)) for p in patterns)
        if score > 0:
            scores[activity] = score
    return max(scores, key=scores.get) if scores else "general"


def get_active_window_title():
    try:
        import pygetwindow as gw
        win = gw.getActiveWindow()
        return win.title if win else ""
    except Exception:
        return ""


# ── Text cleaning ──────────────────────────────────────────────────────────────

def clean_ocr_text(raw):
    lines = raw.splitlines()
    cleaned = []
    for line in lines:
        line = line.strip()
        if len(line) < 3:
            continue
        alpha_ratio = sum(
            c.isalnum() or c in " .,!?:;-$%()/@#_=+*[]{}|\\<>\"'"
            for c in line
        ) / max(len(line), 1)
        if alpha_ratio < 0.40:
            continue
        line = re.sub(r" {3,}", "  ", line)
        cleaned.append(line)
    deduped = []
    for line in cleaned:
        if not deduped or line != deduped[-1]:
            deduped.append(line)
    return "\n".join(deduped)


# ── Frame helpers ──────────────────────────────────────────────────────────────

def _capture_grey(sct, monitor):
    raw = sct.grab(monitor)
    img = Image.frombytes("RGB", raw.size, raw.bgra, "raw", "BGRX")
    return np.array(img.convert("L"))


def _pixel_diff(a, b):
    diff = np.abs(a.astype(np.int16) - b.astype(np.int16))
    return float(np.mean(diff > 12))


def _ocr_full(sct, monitor):
    raw  = sct.grab(monitor)
    img  = Image.frombytes("RGB", raw.size, raw.bgra, "raw", "BGRX")
    text = pytesseract.image_to_string(img, config="--psm 3 --oem 3")
    return clean_ocr_text(text)


# ── Main loop ──────────────────────────────────────────────────────────────────

def _watch_loop():
    global _prev_frame, _last_text, _last_activity, _running, _last_change_t

    with mss.mss() as sct:
        monitors = sct.monitors
        monitor  = monitors[min(MONITOR_INDEX, len(monitors) - 1)]
        w, h     = monitor["width"], monitor["height"]

        print(f"[Vision] IGGY is watching — monitor {MONITOR_INDEX} ({w}x{h}). Always on.")

        while _running:
            try:
                idle_time = time.time() - _last_change_t
                interval  = IDLE_INTERVAL if idle_time > IDLE_PAUSE else CAPTURE_INTERVAL

                frame   = _capture_grey(sct, monitor)
                changed = (_prev_frame is None or
                           _pixel_diff(_prev_frame, frame) >= CHANGE_THRESHOLD)

                if changed:
                    _last_change_t = time.time()
                    text = _ocr_full(sct, monitor)[:MAX_TEXT_LENGTH].strip()

                    if len(text) >= MIN_TEXT_LENGTH and text != _last_text:
                        activity  = detect_activity(text)
                        win_title = get_active_window_title()
                        ts        = datetime.now().strftime("%H:%M:%S")

                        _last_text     = text
                        _last_activity = activity

                        entry = {
                            "ts":       ts,
                            "activity": activity,
                            "window":   win_title,
                            "preview":  text[:120].replace("\n", " "),
                            "full":     text,
                        }
                        _activity_log.append(entry)

                        label = activity.upper()
                        if win_title:
                            label += f" | {win_title[:55]}"
                        print(f"[Vision] [{ts}] {label}")
                        print(f"          > {text[:80].replace(chr(10), ' ')}...")

                        with _lock:
                            if _on_change_cb is not None:
                                try:
                                    _on_change_cb(text, ts, activity, win_title)
                                except Exception as e:
                                    print(f"[Vision] Callback error: {e}")

                _prev_frame = frame
                time.sleep(interval)

            except Exception as e:
                print(f"[Vision] Loop error: {e}")
                time.sleep(3)

    print("[Vision] Stopped.")


# ── Public API ─────────────────────────────────────────────────────────────────

def start(on_change=None, monitor_index=MONITOR_INDEX):
    """
    Start IGGY's eyes in a background daemon thread.

    on_change: callable(text, timestamp, activity, window_title)
    """
    global _running, _thread, _on_change_cb
    if _running:
        print("[Vision] Already running.")
        return
    _on_change_cb = on_change
    _running      = True
    _thread       = threading.Thread(target=_watch_loop, daemon=True, name="iggy-vision")
    _thread.start()


def stop():
    global _running
    _running = False
    if _thread:
        _thread.join(timeout=4)
    print("[Vision] Stopped.")


def get_last_text():
    return _last_text


def get_last_activity():
    return _last_activity


def get_recent_context(n=4):
    """
    Last n activity entries — used by IGGY to understand what you
    were doing before you asked her something.
    e.g. 'I see you were reading about X just now...'
    """
    return list(_activity_log)[-n:]


# ── Wire into IggyBrain ────────────────────────────────────────────────────────
# Add to IggyBrain.__init__ in iggy_brain_py.py:
#
#   from iggy_vision import start as vision_start, get_recent_context
#
#   def _on_screen_change(text, ts, activity, window):
#       self.store_knowledge(
#           f"[Screen @ {ts}] [{activity}] {text}",
#           source=f"screen:{activity}"
#       )
#   vision_start(on_change=_on_screen_change)
#
#
# Inside think(), before building the prompt add:
#
#   recent = get_recent_context(3)
#   if recent:
#       lines = [f"  [{e['ts']}] {e['activity']}: {e['preview']}" for e in recent]
#       screen_context = "What the user was doing recently:\n" + "\n".join(lines)
#
# ──────────────────────────────────────────────────────────────────────────────


if __name__ == "__main__":
    print("IGGY Vision — watching everything. Ctrl+C to stop.\n")

    def show(text, ts, activity, window):
        print(f"\n{'='*60}")
        print(f"  {ts}  |  {activity.upper()}")
        if window:
            print(f"  Window: {window}")
        print("-"*60)
        print(text[:600])
        print("="*60)

    start(on_change=show)

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        stop()
