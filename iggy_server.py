"""
iggy_server.py
──────────────
Runs IGGY's Python brain as a TCP socket server so iggy_executive.jl
can send messages and get real responses.

Usage (separate terminal, keep running):
    python iggy_server.py

Protocol (newline-delimited JSON):
    Client → Server:  {"type":"chat","text":"hello","context":"..."}\n
    Server → Client:  {"reply":"IGGY's response here"}\n
"""

import socket
import json
import threading
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

# ── Import IGGY brain ─────────────────────────────────────────────────────────
print("[Server] Loading IGGY brain…")
try:
    from iggy_brain import IggyBrain
    brain = IggyBrain()
    print("[Server] ✅ Brain loaded")
except Exception as e:
    brain = None
    print(f"[Server] ⚠  Brain failed to load: {e}")

try:
    from iggy_memory import IggyMemory
    memory = IggyMemory()
    print("[Server] ✅ Memory loaded")
except Exception as e:
    memory = None
    print(f"[Server] ⚠  Memory failed to load: {e}")

# ── Core ask function ─────────────────────────────────────────────────────────
def ask_iggy(text: str, context: str = "") -> str:
    """Generate IGGY's reply using brain + memory."""
    retrieved = ""
    if memory:
        try:
            results = memory.retrieve_knowledge(text, n_results=3)
            chunks = [r.get("text", "") if isinstance(r, dict) else str(r)
                      for r in (results or [])]
            retrieved = " ".join(chunks[:3])
        except Exception:
            pass

    prompt_parts = []
    if context:
        prompt_parts.append(f"[Trading context: {context}]")
    if retrieved:
        prompt_parts.append(f"[IGGY's knowledge: {retrieved[:600]}]")
    prompt_parts.append(f"User: {text}\nIGGY:")
    full_prompt = "\n".join(prompt_parts)

    if brain:
        try:
            reply = brain.generate(full_prompt, max_new_tokens=200)
            # Strip the prompt echo if the model repeated it
            if "IGGY:" in reply:
                reply = reply.split("IGGY:")[-1]
            return reply.strip()
        except Exception as e:
            return f"[Brain error: {e}]"

    return "I'm thinking… (brain not loaded)"

# ── Handle one client ─────────────────────────────────────────────────────────
def handle_client(conn: socket.socket, addr):
    print(f"[Server] 🔗 Connected: {addr}")
    try:
        data = b""
        while True:
            chunk = conn.recv(4096)
            if not chunk:
                break
            data += chunk
            if b"\n" in data:
                break

        line = data.split(b"\n")[0].decode("utf-8").strip()
        if not line:
            return

        msg = json.loads(line)
        text    = msg.get("text", "")
        context = msg.get("context", "")

        print(f"[Server] 💬 {addr}: {text[:80]}")
        reply = ask_iggy(text, context)
        print(f"[Server] 🤖 → {reply[:80]}")

        response = json.dumps({"reply": reply}) + "\n"
        conn.sendall(response.encode("utf-8"))

    except Exception as e:
        print(f"[Server] Error with {addr}: {e}")
        try:
            conn.sendall((json.dumps({"reply": f"[Error: {e}]"}) + "\n").encode())
        except Exception:
            pass
    finally:
        conn.close()

# ── Server ────────────────────────────────────────────────────────────────────
HOST = "127.0.0.1"
PORT = 5050

def run_server():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((HOST, PORT))
    srv.listen(8)
    print(f"[Server] 🚀 IGGY brain server listening on {HOST}:{PORT}")
    print("[Server]    Now run: julia --threads auto iggy_executive.jl")

    try:
        while True:
            conn, addr = srv.accept()
            t = threading.Thread(target=handle_client, args=(conn, addr), daemon=True)
            t.start()
    except KeyboardInterrupt:
        print("\n[Server] Stopped.")
    finally:
        srv.close()

if __name__ == "__main__":
    run_server()
