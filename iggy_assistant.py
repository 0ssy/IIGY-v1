#!/usr/bin/env python3
"""
iggy_assistant.py
─────────────────────────────────────────────────────────────────────────────
Python brain server for IGGY.

Protocol  (newline-delimited JSON over TCP, port 5050):
  Julia  → Python :  {"type": "chat", "text": "...", "context": "..."}\n
  Python → Julia  :  {"reply": "..."}\n

Usage:
  python iggy_assistant.py --server          # run the socket server
  python iggy_assistant.py --test "hello"    # one-shot test without Julia

Dependencies (install once):
  pip install requests          # if using OpenAI-compatible API
  # OR:
  pip install ollama            # if using local Ollama
  # OR:
  pip install llama-cpp-python  # if loading a GGUF model directly
─────────────────────────────────────────────────────────────────────────────
"""

import argparse
import json
import socket
import sys

# ─────────────────────────────────────────────────────────────────────────────
# BACKEND  — swap in whichever LLM you are running
# ─────────────────────────────────────────────────────────────────────────────

# ── Option A: Ollama (recommended for local models) ───────────────────────────
def get_reply_ollama(text: str, context: str) -> str:
    try:
        import ollama
        prompt = f"[Context: {context}]\nUser: {text}\nIGGY:" if context else text
        response = ollama.chat(
            model="tinyllama",   # change to any model you have pulled
            messages=[
                {"role": "system",
                 "content": "You are IGGY, a sharp AI assistant and trading partner."},
                {"role": "user", "content": prompt},
            ]
        )
        return response["message"]["content"].strip()
    except Exception as e:
        return f"[Ollama error: {e}]"


# ── Option B: OpenAI / OpenAI-compatible API ──────────────────────────────────
def get_reply_openai(text: str, context: str) -> str:
    try:
        import openai
        openai.api_key = "YOUR_KEY_HERE"            # or set OPENAI_API_KEY env var
        # openai.api_base = "http://localhost:11434/v1"  # ← point to local Ollama
        prompt = f"[Context: {context}]\nUser: {text}" if context else text
        rsp = openai.ChatCompletion.create(
            model="gpt-3.5-turbo",
            messages=[
                {"role": "system",
                 "content": "You are IGGY, a sharp AI assistant and trading partner."},
                {"role": "user", "content": prompt},
            ],
            max_tokens=512,
            temperature=0.7,
        )
        return rsp["choices"][0]["message"]["content"].strip()
    except Exception as e:
        return f"[OpenAI error: {e}]"


# ── Option C: Stub (no model — for testing the socket plumbing) ───────────────
def get_reply_stub(text: str, context: str) -> str:
    return f"[IGGY stub] You said: «{text}»  |  context: {context or 'none'}"


# ── Active backend — change this line to switch backends ──────────────────────
def get_reply(text: str, context: str) -> str:
    return get_reply_ollama(text, context)
    # return get_reply_openai(text, context)
    # return get_reply_stub(text, context)


# ─────────────────────────────────────────────────────────────────────────────
# SOCKET SERVER
# ─────────────────────────────────────────────────────────────────────────────

def run_server(host: str = "127.0.0.1", port: int = 5050) -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as srv:
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind((host, port))
        srv.listen(5)
        print(f"🐍 IGGY Python brain listening on {host}:{port}", flush=True)

        while True:
            conn, addr = srv.accept()
            try:
                with conn:
                    fobj = conn.makefile("r", encoding="utf-8")
                    line = fobj.readline()
                    if not line:
                        continue
                    req   = json.loads(line)
                    text  = req.get("text", "")
                    ctx   = req.get("context", "")
                    reply = get_reply(text, ctx)
                    response = json.dumps({"reply": reply}) + "\n"
                    conn.sendall(response.encode("utf-8"))
            except Exception as e:
                print(f"Connection error: {e}", flush=True)


# ─────────────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="IGGY Python brain")
    parser.add_argument("--server", action="store_true",
                        help="Run as socket server (default mode)")
    parser.add_argument("--test",   metavar="TEXT",
                        help="One-shot test — print reply and exit")
    parser.add_argument("--host",   default="127.0.0.1")
    parser.add_argument("--port",   default=5050, type=int)
    args = parser.parse_args()

    if args.test:
        print(get_reply(args.test, ""), flush=True)
        sys.exit(0)

    # Default: always run server
    run_server(args.host, args.port)
