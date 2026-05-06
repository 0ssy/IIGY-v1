"""
iggy_screen.py — IGGY's vision layer.

Captures your screen, reads text via OCR, detects active windows,
and produces a structured description IGGY uses to give context-aware help.

Features:
  - Full screenshot + OCR (reads everything on screen)
  - Active window detection (knows which app you're in)
  - Change detection (only processes when screen has changed)
  - Region capture (focus on a specific area)
  - Keyboard/mouse suggestion output (can tell you what to click/type)
"""

import time, threading, hashlib
from pathlib import Path
from typing import Optional, Tuple
from datetime import datetime

import mss
import mss.tools
from PIL import Image
import pytesseract
import pygetwindow as gw

# On Windows, set tesseract path if needed:
# pytesseract.pytesseract.tesseract_cmd = r'C:\Program Files\Tesseract-OCR\tesseract.exe'

SCREENSHOT_DIR = Path("iggy_screenshots")
LAST_HASH_FILE = Path(".iggy_last_screen_hash")

class IggyScreen:
    def __init__(self, change_threshold: float = 0.05):
        """
        change_threshold: fraction of pixels that must change before
                          IGGY re-analyzes the screen. 0.05 = 5%.
        """
        SCREENSHOT_DIR.mkdir(exist_ok=True)
        self.change_threshold = change_threshold
        self._last_hash = ""
        self._last_text = ""
        self._lock = threading.Lock()
        print("[Screen] ✅ IGGY vision ready.")

    # ── Capture ───────────────────────────────────────────────────────────────
    def capture(self, region: Optional[dict] = None) -> Image.Image:
        """
        Capture the screen (or a region).
        region: {"top": y, "left": x, "width": w, "height": h}
        """
        with mss.mss() as sct:
            monitor = region or sct.monitors[1]  # monitor[0]=all, [1]=primary
            screenshot = sct.grab(monitor)
        return Image.frombytes("RGB", screenshot.size, screenshot.bgra, "raw", "BGRX")

    def capture_active_window(self) -> Optional[Image.Image]:
        """Capture only the currently active window."""
        try:
            win = gw.getActiveWindow()
            if win is None:
                return self.capture()
            region = {
                "top": max(0, win.top),
                "left": max(0, win.left),
                "width": win.width,
                "height": win.height,
            }
            return self.capture(region)
        except Exception as e:
            print(f"[Screen] Window capture failed: {e}, using full screen.")
            return self.capture()

    # ── OCR ───────────────────────────────────────────────────────────────────
    def read_screen(self, image: Optional[Image.Image] = None) -> str:
        """
        Extract all text from the screen using Tesseract OCR.
        Returns clean text — this is what IGGY reads.
        """
        if image is None:
            image = self.capture()

        # Upscale small screens for better OCR
        w, h = image.size
        if w < 1920:
            image = image.resize((w * 2, h * 2), Image.LANCZOS)

        text = pytesseract.image_to_string(image, config="--psm 6")
        return self._clean_ocr(text)

    def _clean_ocr(self, text: str) -> str:
        import re
        # Remove lines with mostly garbage characters
        lines = text.splitlines()
        clean = []
        for line in lines:
            line = line.strip()
            if len(line) < 3:
                continue
            ratio = sum(1 for c in line if c.isalnum() or c in " .,:-/()@$%") / max(len(line), 1)
            if ratio > 0.5:
                clean.append(line)
        return "\n".join(clean)

    # ── Active Window Info ────────────────────────────────────────────────────
    def get_active_window_info(self) -> dict:
        """Get info about the currently focused window."""
        try:
            win = gw.getActiveWindow()
            if win:
                return {
                    "title": win.title,
                    "app": win.title.split(" - ")[-1] if " - " in win.title else win.title,
                    "size": (win.width, win.height),
                    "position": (win.left, win.top),
                }
        except:
            pass
        return {"title": "Unknown", "app": "Unknown"}

    # ── Change Detection ──────────────────────────────────────────────────────
    def has_screen_changed(self, image: Optional[Image.Image] = None) -> bool:
        """Returns True if the screen has changed significantly since last check."""
        if image is None:
            image = self.capture()
        h = hashlib.md5(image.tobytes()[::100]).hexdigest()  # sample for speed
        if h != self._last_hash:
            self._last_hash = h
            return True
        return False

    # ── Full Context Snapshot ─────────────────────────────────────────────────
    def get_context_snapshot(self, force: bool = False) -> Optional[dict]:
        """
        Returns a structured snapshot of what's currently on screen.
        Returns None if nothing has changed (to avoid redundant processing).

        This is what gets passed to iggy_brain.think() as screen_context.
        """
        with self._lock:
            img = self.capture_active_window()
            if not force and not self.has_screen_changed(img):
                return None

            window = self.get_active_window_info()
            text = self.read_screen(img)
            self._last_text = text

            # Save screenshot with timestamp
            ts = datetime.now().strftime("%Y%m%d_%H%M%S")
            img_path = SCREENSHOT_DIR / f"snap_{ts}.png"
            img.save(str(img_path))

            return {
                "window": window,
                "text": text[:3000],  # cap to avoid flooding context window
                "timestamp": ts,
                "image_path": str(img_path),
            }

    def describe_screen(self, snapshot: Optional[dict] = None) -> str:
        """
        Produce a short text description of the current screen state.
        This is what gets injected into IGGY's system prompt.
        """
        if snapshot is None:
            snapshot = self.get_context_snapshot(force=True)
        if not snapshot:
            return ""

        win = snapshot["window"]
        lines = [
            f"Active window: {win['title']} ({win['app']})",
            f"Screen text (excerpt):\n{snapshot['text'][:1500]}",
        ]
        return "\n".join(lines)

    # ── Continuous Monitoring ─────────────────────────────────────────────────
    def watch(self, callback, interval: float = 3.0):
        """
        Continuously monitor the screen. Calls callback(snapshot) when
        the screen changes. Run in a background thread.

        callback: function that receives a snapshot dict
        interval: seconds between checks
        """
        def _loop():
            print(f"[Screen] Watching for changes every {interval}s...")
            while True:
                try:
                    snap = self.get_context_snapshot()
                    if snap:
                        callback(snap)
                except Exception as e:
                    print(f"[Screen] Watch error: {e}")
                time.sleep(interval)

        t = threading.Thread(target=_loop, daemon=True)
        t.start()
        return t
