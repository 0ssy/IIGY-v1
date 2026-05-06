#!/usr/bin/env python3
"""
iggy_assistant.py
─────────────────────────────────────────────────────────────────────────────
Python brain server for IGGY.  Supports multiple backends:
  - IggyBrain class (auto-detected, handles missing .generate gracefully)
  - Ollama
  - OpenAI-compatible API
  - Stub (no model, for testing socket plumbing)

Protocol (newline-delimited JSON over TCP, port 5050):
  Julia  → Python :  {"type": "chat", "text": "...", "context": "..."}\n
  Python → Julia  :  {"reply": "..."}\n

Usage:
  python iggy_assistant.py --server
  python iggy_assistant.py --test "hello"
─────────────────────────────────────────────────────────────────────────────
"""

import argparse
import json
import socket
import sys
import traceback

# ─────────────────────────────────────────────────────────────────────────────
# IGGY BRAIN  — wraps your IggyBrain class safely
# ─────────────────────────────────────────────────────────────────────────────

def _call_iggy_brain(text: str, context: str) -> str:
    """
    Try to import and call IggyBrain.  Probes for common method names so it
    works regardless of which one the class actually implements.
    """
    try:
        from iggy_brain import IggyBrain  # type: ignore
    except ImportError:
        return "[IggyBrain module not found — check iggy_brain.py exists]"

    try:
        brain = IggyBrain()
    except Exception as e:
        return f"[IggyBrain init error: {e}]"

    prompt = f"[Context: {context}]\nUser: {text}\nIGGY:" if context else text

    # Try method names in order of likelihood
    for method_name in ("generate", "chat", "respond", "reply", "ask", "__call__"):
        method = getattr(brain, method_name, None)
        if method is not None and callable(method):
            try:
                result = method(prompt)
                if isinstance(result, str):
                    return result.strip()
                for attr in ("text", "content", "output", "response", "message"):
                    val = getattr(result, attr, None)
                    if val is not None:
                        return str(val).strip()
                return str(result).strip()
            except Exception as e:
                return f"[IggyBrain.{method_name} error: {e}]"

    available = [m for m in dir(brain) if not m.startswith("_")]
    return (
        f"[IggyBrain has no recognised generate/chat/respond method. "
        f"Available: {available}]"
    )


# ─────────────────────────────────────────────────────────────────────────────
# OLLAMA BACKEND
# ─────────────────────────────────────────────────────────────────────────────

def _call_ollama(text: str, context: str) -> str:
    try:
        import ollama  # type: ignore
        prompt = f"[Context: {context}]\nUser: {text}\nIGGY:" if context else text
        response = ollama.chat(
            model="tinyllama",
            messages=[
                {"role": "system",
                 "content": "You are IGGY, a sharp AI assistant and trading partner."},
                {"role": "user", "content": prompt},
            ]
        )
        return response["message"]["content"].strip()
    except Exception as e:
        return f"[Ollama error: {e}]"


# ─────────────────────────────────────────────────────────────────────────────
# OPENAI-COMPATIBLE BACKEND
# ─────────────────────────────────────────────────────────────────────────────

def _call_openai(text: str, context: str) -> str:
    try:
        import openai  # type: ignore
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


# ─────────────────────────────────────────────────────────────────────────────
# STUB  (no model — for testing socket plumbing only)
# ─────────────────────────────────────────────────────────────────────────────

def _call_stub(text: str, context: str) -> str:
    return f"[IGGY stub] You said: «{text}»"


# ─────────────────────────────────────────────────────────────────────────────
# ACTIVE BACKEND  — change this one line to switch
# ─────────────────────────────────────────────────────────────────────────────

def get_reply(text: str, context: str) -> str:
    return _call_iggy_brain(text, context)
    # return _call_ollama(text, context)
    # return _call_openai(text, context)
    # return _call_stub(text, context)


# ─────────────────────────────────────────────────────────────────────────────
# SOCKET SERVER
# ─────────────────────────────────────────────────────────────────────────────

def run_server(host: str = "127.0.0.1", port: int = 5050) -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as srv:
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind((host, port))
        srv.listen(5)
        print(f"IGGY Python brain listening on {host}:{port}", flush=True)

        while True:
            conn, addr = srv.accept()
            try:
                with conn:
                    fobj  = conn.makefile("r", encoding="utf-8")
                    line  = fobj.readline()
                    if not line:
                        continue
                    req   = json.loads(line)
                    text  = req.get("text", "")
                    ctx   = req.get("context", "")
                    try:
                        reply = get_reply(text, ctx)
                    except Exception as e:
                        reply = f"[Brain error: {e}]"
                        traceback.print_exc()
                    response = json.dumps({"reply": reply}) + "\n"
                    conn.sendall(response.encode("utf-8"))
            except Exception as e:
                print(f"Connection error: {e}", flush=True)


# ─────────────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="IGGY Python brain server")
    parser.add_argument("--server", action="store_true", help="Run as socket server")
    parser.add_argument("--test",   metavar="TEXT",      help="One-shot test and exit")
    parser.add_argument("--host",   default="127.0.0.1")
    parser.add_argument("--port",   default=5050, type=int)
    args = parser.parse_args()

    if args.test:
        print(get_reply(args.test, ""), flush=True)
        sys.exit(0)

    run_server(args.host, args.port)
