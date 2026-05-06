"""
iggy_trainer.py — IGGY's continuous learning scheduler.

Runs as a background thread/process.
Every N minutes it checks the training queue and triggers a LoRA
fine-tune pass if enough new data has arrived.

Also handles:
  - Conversation-to-training conversion (learns from her own chats)
  - Topic prioritization (learns what YOU care about more)
  - Training history logging
"""

import json, time, threading
from pathlib import Path
from datetime import datetime
from typing import Optional

TRAIN_QUEUE    = Path("iggy_train_queue.jsonl")
TRAIN_LOG      = Path("iggy_training_log.jsonl")
CONVO_QUEUE    = Path("iggy_convo_queue.jsonl")   # conversations → training data

MIN_SAMPLES_TO_TRAIN = 30     # don't train until we have this many new samples
TRAIN_INTERVAL_MIN   = 60     # check every 60 minutes
CONVO_WEIGHT         = 3      # repeat conversation examples N times (they matter more)


class IggyTrainer:
    def __init__(self, brain=None):
        """brain: IggyBrain instance. Pass it in after the brain is loaded."""
        self.brain = brain
        self._running = False
        self._thread: Optional[threading.Thread] = None

    def set_brain(self, brain):
        self.brain = brain

    # ── Queue Management ──────────────────────────────────────────────────────
    def queue_conversation(self, user_msg: str, iggy_response: str):
        """
        Every time IGGY has a good conversation, queue it for fine-tuning.
        This makes her better at the kinds of things YOU talk to her about.
        """
        entry = {
            "text": (
                f"<|user|>\n{user_msg}</s>\n"
                f"<|assistant|>\n{iggy_response}</s>"
            ),
            "source": "conversation",
            "timestamp": datetime.utcnow().isoformat(),
        }
        # Weight conversations more by repeating them
        with CONVO_QUEUE.open("a") as f:
            for _ in range(CONVO_WEIGHT):
                f.write(json.dumps(entry) + "\n")

    def queue_correction(self, user_msg: str, corrected_response: str):
        """
        When you correct IGGY, queue the correction with extra weight.
        'No IGGY, that's wrong, here's the right answer: ...'
        This is how she learns from mistakes.
        """
        entry = {
            "text": (
                f"<|user|>\n{user_msg}</s>\n"
                f"<|assistant|>\n{corrected_response}</s>"
            ),
            "source": "correction",
            "timestamp": datetime.utcnow().isoformat(),
        }
        with TRAIN_QUEUE.open("a") as f:
            for _ in range(CONVO_WEIGHT * 2):  # corrections get extra weight
                f.write(json.dumps(entry) + "\n")
        print(f"[Trainer] ✏️ Correction queued (high priority).")

    def merge_conversation_queue(self):
        """Move conversation examples into the main training queue."""
        if not CONVO_QUEUE.exists():
            return 0
        convos = CONVO_QUEUE.read_text().strip()
        if not convos:
            return 0
        count = len(convos.splitlines())
        with TRAIN_QUEUE.open("a") as f:
            f.write(convos + "\n")
        CONVO_QUEUE.write_text("")
        print(f"[Trainer] Merged {count} conversation examples into training queue.")
        return count

    def queue_size(self) -> int:
        if not TRAIN_QUEUE.exists():
            return 0
        return len([l for l in TRAIN_QUEUE.read_text().splitlines() if l.strip()])

    # ── Training Trigger ──────────────────────────────────────────────────────
    def check_and_train(self):
        """Check if it's time to train, and do so if yes."""
        self.merge_conversation_queue()
        size = self.queue_size()
        print(f"[Trainer] Queue size: {size} samples (need {MIN_SAMPLES_TO_TRAIN} to train)")

        if size < MIN_SAMPLES_TO_TRAIN:
            return False

        if self.brain is None:
            print("[Trainer] Brain not set — skipping training.")
            return False

        print(f"[Trainer] 🧠 Starting training run with {size} samples...")
        start = time.time()
        self.brain.learn_from_queue(min_samples=MIN_SAMPLES_TO_TRAIN)
        elapsed = time.time() - start

        # Log training event
        log_entry = {
            "timestamp": datetime.utcnow().isoformat(),
            "samples": size,
            "duration_seconds": round(elapsed, 1),
        }
        with TRAIN_LOG.open("a") as f:
            f.write(json.dumps(log_entry) + "\n")
        print(f"[Trainer] ✅ Training complete in {elapsed:.1f}s")
        return True

    # ── Background Loop ───────────────────────────────────────────────────────
    def start(self):
        """Start the background training scheduler thread."""
        if self._running:
            return
        self._running = True
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()
        print(f"[Trainer] Background trainer started (interval: {TRAIN_INTERVAL_MIN}min)")

    def stop(self):
        self._running = False

    def _loop(self):
        while self._running:
            try:
                self.check_and_train()
            except Exception as e:
                print(f"[Trainer] Error: {e}")
            time.sleep(TRAIN_INTERVAL_MIN * 60)

    def training_history(self) -> list:
        if not TRAIN_LOG.exists():
            return []
        return [json.loads(l) for l in TRAIN_LOG.read_text().splitlines() if l.strip()]
