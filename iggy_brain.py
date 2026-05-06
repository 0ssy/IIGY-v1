"""
iggy_brain.py — IGGY's actual cognitive core.

Uses TinyLlama (free, local, no API key) as the base model.
Knowledge from the crawler is injected via ChromaDB retrieval.
Periodic LoRA fine-tuning updates her actual weights with what she's learned.

To swap to a larger model later, just change MODEL_NAME.
Tested with: TinyLlama/TinyLlama-1.1B-Chat-v1.0 (600MB, runs on CPU)
             microsoft/phi-2                        (2.7B, needs ~6GB RAM)
             mistralai/Mistral-7B-Instruct-v0.2     (7B, needs ~16GB RAM)
"""

import os, json, time, threading
from pathlib import Path
from datetime import datetime
from typing import Optional

import torch
from transformers import (
    AutoTokenizer, AutoModelForCausalLM,
    TrainingArguments, Trainer, DataCollatorForLanguageModeling
)
from datasets import Dataset
from peft import LoraConfig, get_peft_model, TaskType, PeftModel

# ── Config ────────────────────────────────────────────────────────────────────
MODEL_NAME   = "TinyLlama/TinyLlama-1.1B-Chat-v1.0"
ADAPTER_DIR  = Path("iggy_adapters")       # LoRA adapters saved here
TRAIN_QUEUE  = Path("iggy_train_queue.jsonl")  # crawler writes here
IGGY_PERSONA = (
    "You are IGGY — a sharp, evolving personal AI assistant. "
    "You are direct, intelligent, and grow smarter from everything you learn. "
    "You have access to your own continuously updated knowledge base. "
    "When you don't know something, say so. Never hallucinate. "
    "You assist with trading insights, research, screen analysis, and strategy."
)

# ── IggyBrain ─────────────────────────────────────────────────────────────────
class IggyBrain:
    def __init__(self, memory=None):
        """
        memory: IggyMemory instance (optional). If provided, IGGY retrieves
                relevant knowledge before every response.
        """
        self.memory = memory
        self.device = "cuda" if torch.cuda.is_available() else "cpu"
        print(f"[IGGY Brain] Loading {MODEL_NAME} on {self.device}...")

        self.tokenizer = AutoTokenizer.from_pretrained(MODEL_NAME)
        self.tokenizer.pad_token = self.tokenizer.eos_token

        self.model = AutoModelForCausalLM.from_pretrained(
            MODEL_NAME,
            torch_dtype=torch.float16 if self.device == "cuda" else torch.float32,
            low_cpu_mem_usage=True,
        )

        # Load LoRA adapter if one exists (from previous training)
        if (ADAPTER_DIR / "adapter_config.json").exists():
            print("[IGGY Brain] Loading fine-tuned LoRA adapter...")
            self.model = PeftModel.from_pretrained(self.model, str(ADAPTER_DIR))

        self.model.to(self.device)
        self.model.eval()
        self._lock = threading.Lock()  # thread-safe inference
        print("[IGGY Brain] ✅ Ready.")

    # ── Inference ─────────────────────────────────────────────────────────────
    def think(
        self,
        user_input: str,
        screen_context: str = "",
        conversation_history: list = None,
        max_new_tokens: int = 400,
    ) -> str:
        """
        Core reasoning function. Retrieves relevant memory, builds prompt,
        generates response.
        """
        # 1. Retrieve relevant knowledge from IGGY's own memory
        retrieved = ""
        if self.memory:
            hits = self.memory.retrieve(user_input, n=4)
            if hits:
                retrieved = "\n".join(f"- {h}" for h in hits)
                retrieved = f"\n[IGGY's Knowledge]\n{retrieved}\n"

        # 2. Build context block
        context_parts = [IGGY_PERSONA]
        if retrieved:
            context_parts.append(retrieved)
        if screen_context:
            context_parts.append(f"\n[Screen]\n{screen_context}")
        system_prompt = "\n".join(context_parts)

        # 3. Build TinyLlama chat format
        messages = [{"role": "system", "content": system_prompt}]
        if conversation_history:
            for turn in conversation_history[-6:]:   # keep last 3 exchanges
                messages.append(turn)
        messages.append({"role": "user", "content": user_input})

        prompt = self._format_chat(messages)

        # 4. Generate
        with self._lock:
            inputs = self.tokenizer(prompt, return_tensors="pt", truncation=True, max_length=2048)
            inputs = {k: v.to(self.device) for k, v in inputs.items()}

            with torch.no_grad():
                output_ids = self.model.generate(
                    **inputs,
                    max_new_tokens=max_new_tokens,
                    do_sample=True,
                    temperature=0.72,
                    top_p=0.9,
                    repetition_penalty=1.15,
                    pad_token_id=self.tokenizer.eos_token_id,
                )

        # 5. Decode only the new tokens
        new_tokens = output_ids[0][inputs["input_ids"].shape[1]:]
        response = self.tokenizer.decode(new_tokens, skip_special_tokens=True).strip()
        return response

    def _format_chat(self, messages: list) -> str:
        """TinyLlama chat template."""
        prompt = ""
        for m in messages:
            role = m["role"]
            content = m["content"]
            if role == "system":
                prompt += f"<|system|>\n{content}</s>\n"
            elif role == "user":
                prompt += f"<|user|>\n{content}</s>\n"
            elif role == "assistant":
                prompt += f"<|assistant|>\n{content}</s>\n"
        prompt += "<|assistant|>\n"
        return prompt

    # ── Continuous Learning ───────────────────────────────────────────────────
    def learn_from_queue(self, min_samples: int = 20):
        """
        Called periodically by iggy_trainer.py.
        Reads iggy_train_queue.jsonl, fine-tunes with LoRA, saves adapter.
        Only trains when enough new data has accumulated.
        """
        if not TRAIN_QUEUE.exists():
            return

        lines = TRAIN_QUEUE.read_text().strip().splitlines()
        if len(lines) < min_samples:
            print(f"[Trainer] Only {len(lines)} samples — waiting for {min_samples} before training.")
            return

        print(f"[Trainer] Starting LoRA fine-tune on {len(lines)} samples...")
        texts = [json.loads(l)["text"] for l in lines if l.strip()]

        # Tokenize
        def tokenize(batch):
            return self.tokenizer(
                batch["text"],
                truncation=True,
                max_length=512,
                padding="max_length",
            )

        dataset = Dataset.from_dict({"text": texts}).map(tokenize, batched=True)
        dataset = dataset.remove_columns(["text"])
        dataset.set_format("torch")

        # LoRA config — lightweight, doesn't need GPU
        lora_cfg = LoraConfig(
            task_type=TaskType.CAUSAL_LM,
            r=8, lora_alpha=16, lora_dropout=0.05,
            target_modules=["q_proj", "v_proj"],
        )

        # Detach adapter for fresh training pass
        base_model = self.model.base_model if hasattr(self.model, "base_model") else self.model
        peft_model = get_peft_model(base_model, lora_cfg)
        peft_model.print_trainable_parameters()

        args = TrainingArguments(
            output_dir=str(ADAPTER_DIR),
            num_train_epochs=2,
            per_device_train_batch_size=2,
            gradient_accumulation_steps=4,
            learning_rate=2e-4,
            fp16=(self.device == "cuda"),
            logging_steps=10,
            save_strategy="epoch",
            report_to="none",
        )

        trainer = Trainer(
            model=peft_model,
            args=args,
            train_dataset=dataset,
            data_collator=DataCollatorForLanguageModeling(self.tokenizer, mlm=False),
        )

        trainer.train()
        peft_model.save_pretrained(str(ADAPTER_DIR))
        print(f"[Trainer] ✅ Adapter saved to {ADAPTER_DIR}")

        # Archive trained samples, clear queue
        archive = Path("iggy_train_archive.jsonl")
        with archive.open("a") as f:
            f.write("\n".join(lines) + "\n")
        TRAIN_QUEUE.write_text("")  # clear queue

        # Hot-reload the new adapter
        print("[Trainer] Hot-reloading updated adapter...")
        with self._lock:
            self.model = PeftModel.from_pretrained(base_model, str(ADAPTER_DIR))
            self.model.to(self.device)
            self.model.eval()
        print("[Trainer] ✅ IGGY's brain updated.")
