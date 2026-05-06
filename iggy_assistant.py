"""
iggy_assistant.py — IGGY's main loop. Start here.

Runs all components together:
  - Brain (local LLM)
  - Memory (ChromaDB knowledge store)
  - Crawler (web knowledge acquisition)
  - Screen (sees what you see)
  - Trainer (continuous learning)
  - Julia bridge (talks to the trading system)

Usage:
    python iggy_assistant.py              # normal mode
    python iggy_assistant.py --no-screen  # skip screen capture
    python iggy_assistant.py --crawl "topic you want IGGY to learn"
"""

import asyncio, sys, json, socket, threading, time
from pathlib import Path
from datetime import datetime
from typing import Optional

from iggy_memory import IggyMemory
from iggy_brain import IggyBrain
from iggy_trainer import IggyTrainer

# Optional imports (gracefully skip if not available on this machine)
try:
    from iggy_screen import IggyScreen
    SCREEN_AVAILABLE = True
except ImportError:
    SCREEN_AVAILABLE = False
    print("[Warning] Screen module unavailable (install mss, pytesseract, pygetwindow)")

try:
    from iggy_crawler import IggyCrawler
    CRAWLER_AVAILABLE = True
except ImportError:
    CRAWLER_AVAILABLE = False
    print("[Warning] Crawler unavailable (install playwright)")

# ── Config ────────────────────────────────────────────────────────────────────
JULIA_BRIDGE_PORT = 9999   # socket port for Julia trading system communication
SCREEN_INTERVAL   = 5.0    # seconds between screen checks
CRAWL_TOPICS_FILE = Path("iggy_crawl_topics.txt")

STARTUP_BANNER = """
╔══════════════════════════════════════════╗
║         I G G Y  —  v2.0                ║
║   Your Personal AI. Always Learning.    ║
╚══════════════════════════════════════════╝
  Brain: TinyLlama (local, no API needed)
  Memory: ChromaDB (persistent knowledge)
  Screen: Live context awareness
  Crawler: Continuous web learning
  Trader: Julia bridge active
──────────────────────────────────────────
  Type 'help' for commands
  Type 'exit' to quit
──────────────────────────────────────────
"""

HELP_TEXT = """
IGGY Commands:
  help                  — show this
  exit / quit           — shut down
  memory stats          — show knowledge base size
  crawl <topic/url>     — teach IGGY about something now
  learn from <url>      — crawl a specific URL
  correct: <response>   — correct IGGY's last answer
  screen on/off         — toggle screen awareness
  trade status          — get trading system status from Julia
  topics                — list crawl topics
  add topic <topic>     — add a topic to auto-crawl list
"""

# ── Julia Bridge ──────────────────────────────────────────────────────────────
class JuliaBridge:
    """Simple socket bridge to talk to the Julia trading system."""
    def __init__(self, port: int = JULIA_BRIDGE_PORT):
        self.port = port
        self._server = None

    def start_server(self):
        """Start a TCP server that Julia can connect to."""
        def _serve():
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                try:
                    s.bind(('127.0.0.1', self.port))
                    s.listen(1)
                    print(f"[Julia Bridge] Listening on port {self.port}")
                    while True:
                        conn, _ = s.accept()
                        with conn:
                            data = conn.recv(4096).decode()
                            if data:
                                self._handle_julia_message(data)
                except OSError:
                    print(f"[Julia Bridge] Port {self.port} unavailable — bridge disabled")

        t = threading.Thread(target=_serve, daemon=True)
        t.start()

    def _handle_julia_message(self, msg: str):
        """Process messages from Julia (trade signals, status updates, etc.)"""
        print(f"[Julia] {msg}")

    def send_to_julia(self, msg: str) -> Optional[str]:
        """Send a message to Julia and get a response."""
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                s.settimeout(3.0)
                s.connect(('127.0.0.1', self.port))
                s.send(msg.encode())
                return s.recv(4096).decode()
        except:
            return None

# ── IggyAssistant ─────────────────────────────────────────────────────────────
class IggyAssistant:
    def __init__(self, use_screen: bool = True):
        print(STARTUP_BANNER)

        # Core modules
        print("[Boot] Loading memory...")
        self.memory = IggyMemory()

        print("[Boot] Loading brain (this takes 30–60s first time)...")
        self.brain = IggyBrain(memory=self.memory)

        print("[Boot] Starting trainer...")
        self.trainer = IggyTrainer(brain=self.brain)
        self.trainer.start()

        # Screen
        self.screen = None
        self.use_screen = use_screen and SCREEN_AVAILABLE
        if self.use_screen:
            print("[Boot] Starting screen monitor...")
            self.screen = IggyScreen()

        # Crawler
        self.crawler = None
        if CRAWLER_AVAILABLE:
            self.crawler = IggyCrawler(memory=self.memory)

        # Julia bridge
        self.julia = JuliaBridge()
        self.julia.start_server()

        # Conversation state
        self.history = []
        self.last_iggy_response = ""
        self.screen_context = ""

        # Start screen watcher if enabled
        if self.screen:
            self.screen.watch(self._on_screen_change, interval=SCREEN_INTERVAL)

        print("\n[Boot] ✅ IGGY is online.\n")
        stats = self.memory.stats()
        print(f"[Memory] {stats['knowledge_chunks']} knowledge chunks | {stats['conversation_turns']} conversations stored\n")

    # ── Screen Callback ────────────────────────────────────────────────────────
    def _on_screen_change(self, snapshot: dict):
        """Called when screen changes. Update IGGY's context."""
        self.screen_context = self.screen.describe_screen(snapshot)
        # Optionally: auto-suggest when IGGY sees something interesting
        # win = snapshot["window"]["title"]
        # if "error" in snapshot["text"].lower():
        #     asyncio.run(self._auto_suggest())

    # ── Core Interaction ───────────────────────────────────────────────────────
    def chat(self, user_input: str) -> str:
        """Send a message to IGGY and get a response."""
        response = self.brain.think(
            user_input=user_input,
            screen_context=self.screen_context if self.use_screen else "",
            conversation_history=self.history,
        )
        self.last_iggy_response = response

        # Store in memory
        self.memory.store_conversation(user_input, response)

        # Queue for training
        self.trainer.queue_conversation(user_input, response)

        # Update history
        self.history.append({"role": "user", "content": user_input})
        self.history.append({"role": "assistant", "content": response})
        if len(self.history) > 20:
            self.history = self.history[-20:]

        return response

    # ── Command Handler ────────────────────────────────────────────────────────
    def handle_command(self, cmd: str) -> Optional[str]:
        """Handle special IGGY commands. Returns response string or None."""
        cmd = cmd.strip()

        if cmd == "help":
            return HELP_TEXT

        if cmd in ("exit", "quit"):
            return "__EXIT__"

        if cmd == "memory stats":
            stats = self.memory.stats()
            hist = self.trainer.training_history()
            return (
                f"Knowledge chunks: {stats['knowledge_chunks']}\n"
                f"Conversation turns: {stats['conversation_turns']}\n"
                f"Training runs: {len(hist)}\n"
                f"Training queue: {self.trainer.queue_size()} samples"
            )

        if cmd.startswith("crawl ") or cmd.startswith("learn from "):
            if not self.crawler:
                return "Crawler not available. Install playwright: pip install playwright && playwright install chromium"
            target = cmd.replace("crawl ", "").replace("learn from ", "").strip()
            print(f"[IGGY] Crawling '{target}' in background...")
            def _crawl():
                import asyncio
                if target.startswith("http"):
                    asyncio.run(self.crawler.crawl_url(target, topic=target))
                else:
                    asyncio.run(self.crawler.search_and_crawl(target, num_results=5))
                stats = self.memory.stats()
                print(f"\n[IGGY] Done learning about '{target}'. Knowledge: {stats['knowledge_chunks']} chunks")
            threading.Thread(target=_crawl, daemon=True).start()
            return f"IGGY is learning about '{target}' in the background. I'll have it ready shortly."

        if cmd.startswith("correct:"):
            correction = cmd[8:].strip()
            if self.history and self.last_iggy_response:
                last_user = next(
                    (h["content"] for h in reversed(self.history) if h["role"] == "user"),
                    ""
                )
                self.trainer.queue_correction(last_user, correction)
                return "Got it. I've noted the correction and will learn from it."
            return "No recent response to correct."

        if cmd == "screen on":
            if SCREEN_AVAILABLE:
                self.use_screen = True
                if not self.screen:
                    self.screen = IggyScreen()
                    self.screen.watch(self._on_screen_change)
                return "Screen awareness ON."
            return "Screen module not installed."

        if cmd == "screen off":
            self.use_screen = False
            self.screen_context = ""
            return "Screen awareness OFF."

        if cmd == "trade status":
            resp = self.julia.send_to_julia("status")
            return f"Trading system: {resp}" if resp else "Trading system not responding."

        if cmd == "topics":
            if CRAWL_TOPICS_FILE.exists():
                return CRAWL_TOPICS_FILE.read_text() or "No topics set yet."
            return "No topics set yet. Use 'add topic <topic>' to add one."

        if cmd.startswith("add topic "):
            topic = cmd[10:].strip()
            with CRAWL_TOPICS_FILE.open("a") as f:
                f.write(topic + "\n")
            return f"Added '{topic}' to auto-crawl list."

        return None  # not a command

    # ── Main Loop ──────────────────────────────────────────────────────────────
    def run(self):
        while True:
            try:
                user_input = input("You > ").strip()
                if not user_input:
                    continue

                # Check for commands first
                cmd_result = self.handle_command(user_input.lower())
                if cmd_result == "__EXIT__":
                    print("IGGY > Goodbye. Saving state...")
                    break
                if cmd_result is not None:
                    print(f"IGGY > {cmd_result}\n")
                    continue

                # Regular conversation
                print("IGGY > ", end="", flush=True)
                response = self.chat(user_input)
                print(response)
                print()

            except KeyboardInterrupt:
                print("\nIGGY > Interrupted. Shutting down...")
                break
            except Exception as e:
                print(f"[Error] {e}")


# ── Entry Point ────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    use_screen = "--no-screen" not in sys.argv

    # Quick crawl mode: python iggy_assistant.py --crawl "bitcoin trading strategies"
    if "--crawl" in sys.argv:
        idx = sys.argv.index("--crawl")
        topic = " ".join(sys.argv[idx + 1:]) if idx + 1 < len(sys.argv) else ""
        if topic and CRAWLER_AVAILABLE:
            from iggy_memory import IggyMemory
            from iggy_crawler import IggyCrawler
            mem = IggyMemory()
            crawler = IggyCrawler(memory=mem)
            if topic.startswith("http"):
                asyncio.run(crawler.crawl_url(topic))
            else:
                asyncio.run(crawler.search_and_crawl(topic, num_results=6))
            print(f"\nDone. Memory: {mem.stats()}")
        sys.exit(0)

    iggy = IggyAssistant(use_screen=use_screen)
    iggy.run()
