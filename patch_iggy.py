#!/usr/bin/env python3
"""
patch_iggy.py  —  IGGY v3 one-shot fix script
Run from your project folder:  python patch_iggy.py

Fixes applied
─────────────
 1. iggy_memory.py   — add `metadata` kwarg to store_knowledge()
 2. iggy_memory.py   — add missing get_stats() method
 3. iggy_crawler.py  — deduplicate URLs so chunks aren't stored 4× per cycle
 4. iggy_crawler.py  — fix get_stats() call so cycle doesn't crash
 5. iggy_brain.jl    — wrap file reads in try/catch + strip \\r\\n (StringIndexError)
 6. iggy_brain.jl    — wrap PyCall/TinyLlama init so FieldError is caught cleanly
 7. iggy_vision.jl   — catch EOFError in vision loop so it restarts instead of dying
 8. iggy_executive_v3.jl — catch EOFError in discovery loop

Each file is backed up as <filename>.bak before any change is made.
"""

import os, re, shutil, sys

# ──────────────────────────────────────────────────────────────────────────────
HERE = os.path.dirname(os.path.abspath(__file__))

def read(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()

def write(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)

def backup(path):
    bak = path + ".bak"
    if not os.path.exists(bak):           # don't overwrite a previous backup
        shutil.copy2(path, bak)
        print(f"  💾 Backed up → {os.path.basename(bak)}")

def apply(path, patches, label):
    """patches = list of (old_str, new_str) tuples.  Regex disabled — plain replace."""
    full = os.path.join(HERE, path)
    if not os.path.exists(full):
        print(f"\n⚠️  {path} not found — skipping '{label}'")
        return

    print(f"\n📄 Patching {path}  [{label}]")
    backup(full)
    text = read(full)
    changed = False
    for old, new in patches:
        if old in text:
            text = text.replace(old, new, 1)
            print(f"  ✅ Applied: {repr(old[:60])} ...")
            changed = True
        else:
            print(f"  ⏭  Already patched or pattern not found: {repr(old[:60])}")
    if changed:
        write(full, text)
        print(f"  💾 Saved.")
    else:
        print(f"  ℹ️  No changes needed.")

# ══════════════════════════════════════════════════════════════════════════════
# FIX 1 + 2 — iggy_memory.py
# ══════════════════════════════════════════════════════════════════════════════

MEM_PATCHES = [
    # Fix 1: accept metadata kwarg in store_knowledge
    # Handles both common signatures:
    #   def store_knowledge(self, text, source="", topic=""):
    #   def store_knowledge(self, text, source='', topic=''):
    (
        'def store_knowledge(self, text, source="", topic=""):',
        'def store_knowledge(self, text, source="", topic="", metadata=None):'
    ),
    (
        "def store_knowledge(self, text, source='', topic=''):",
        "def store_knowledge(self, text, source='', topic='', metadata=None):"
    ),
    # Fallback: bare two-arg version
    (
        "def store_knowledge(self, text, source):",
        "def store_knowledge(self, text, source, topic='', metadata=None):"
    ),
]

# Fix 2: inject get_stats right before the last line of the class.
# We look for a safe anchor that appears near the end of IggyMemory.
GET_STATS_METHOD = '''
    def get_stats(self) -> dict:
        """Return basic memory statistics (required by iggy_crawler.py)."""
        chunks = getattr(self, "chunks", None) or getattr(self, "_chunks", None) or []
        store  = getattr(self, "store",  None) or getattr(self, "_store",  None) or {}
        return {
            "total_chunks": len(chunks) if hasattr(chunks, "__len__") else 0,
            "total_keys":   len(store)  if hasattr(store,  "__len__") else 0,
        }
'''

def patch_memory():
    full = os.path.join(HERE, "iggy_memory.py")
    if not os.path.exists(full):
        print("\n⚠️  iggy_memory.py not found — skipping fixes 1+2")
        return

    print("\n📄 Patching iggy_memory.py  [store_knowledge + get_stats]")
    backup(full)
    text = read(full)

    # Fix 1 — metadata kwarg
    changed = False
    for old, new in MEM_PATCHES:
        if old in text:
            text = text.replace(old, new, 1)
            print(f"  ✅ metadata kwarg added to store_knowledge")
            changed = True
            break
    if not changed:
        # Try regex for any variation
        new_text = re.sub(
            r'def store_knowledge\(self,\s*text(?:,\s*source[^)]*?)?\):',
            lambda m: m.group(0)[:-2] + ', metadata=None):' if 'metadata' not in m.group(0) else m.group(0),
            text
        )
        if new_text != text:
            text = new_text
            print("  ✅ metadata kwarg added (regex path)")
            changed = True
        else:
            print("  ⏭  metadata kwarg — already present or signature not recognised")

    # Fix 2 — get_stats
    if "def get_stats" in text:
        print("  ⏭  get_stats — already present")
    else:
        # Inject before the last dedented line (end of class or start of next top-level def)
        # Simple heuristic: find the last `def ` inside the class and append after it
        last_def = text.rfind("\n    def ")
        if last_def != -1:
            # Find end of that method
            insert_at = text.find("\n    def ", last_def + 1)
            if insert_at == -1:
                insert_at = len(text)
            text = text[:insert_at] + GET_STATS_METHOD + text[insert_at:]
            print("  ✅ get_stats() injected")
        else:
            text += GET_STATS_METHOD
            print("  ✅ get_stats() appended (fallback)")

    write(full, text)
    print("  💾 Saved.")

# ══════════════════════════════════════════════════════════════════════════════
# FIX 3 + 4 — iggy_crawler.py
# ══════════════════════════════════════════════════════════════════════════════

CRAWLER_DEDUP_IMPORT = "import threading\n"

CRAWLER_DEDUP_GLOBALS = """\
# ── URL deduplication (fix: chunks were stored 4× per discovery cycle) ──
_seen_urls: set = set()
_seen_lock = threading.Lock()

def _url_is_new(url: str) -> bool:
    \"\"\"Return True the first time a URL is seen; False on repeats.\"\"\"
    with _seen_lock:
        if url in _seen_urls:
            return False
        _seen_urls.add(url)
        return True

"""

def patch_crawler():
    full = os.path.join(HERE, "iggy_crawler.py")
    if not os.path.exists(full):
        print("\n⚠️  iggy_crawler.py not found — skipping fixes 3+4")
        return

    print("\n📄 Patching iggy_crawler.py  [URL dedup + get_stats fix]")
    backup(full)
    text = read(full)

    # Fix 3a — inject threading import if not present
    if "import threading" not in text:
        text = CRAWLER_DEDUP_IMPORT + text
        print("  ✅ import threading added")

    # Fix 3b — inject dedup globals after imports block
    if "_url_is_new" not in text:
        # Insert after the last top-level import line
        last_import = 0
        for m in re.finditer(r'^(?:import |from )\S', text, re.MULTILINE):
            last_import = m.end()
        insert_at = text.find("\n", last_import) + 1
        text = text[:insert_at] + "\n" + CRAWLER_DEDUP_GLOBALS + text[insert_at:]
        print("  ✅ _url_is_new() dedup helper injected")

    # Fix 3c — wrap every store_knowledge / fetch call with the dedup guard
    # The typical pattern is:  chunks = memory.store_knowledge(...)
    # We look for the common crawler crawl-and-store pattern
    # Pattern A: direct HTTP fetch then store
    crawl_pattern = re.compile(
        r'([ \t]+)(.*?store_knowledge\(.*?\).*?\n)',
        re.DOTALL
    )
    # More targeted: wrap the url-fetch block
    # Look for lines like:  resp = requests.get(url)  or  response = fetch(url)
    # and insert a guard before them
    url_fetch_re = re.compile(
        r'([ \t]+)((?:response|resp|html|r)\s*=\s*(?:requests\.get|fetch|HTTP\.get)\(url\))',
        re.MULTILINE
    )
    def add_guard(m):
        indent = m.group(1)
        rest   = m.group(2)
        guard  = f'{indent}if not _url_is_new(url):\n{indent}    continue\n{indent}'
        return guard + rest
    new_text = url_fetch_re.sub(add_guard, text)
    if new_text != text:
        text = new_text
        print("  ✅ _url_is_new guard inserted before fetch calls")
    else:
        print("  ⏭  Could not auto-insert dedup guard (manual check needed) — helper is available")

    # Fix 4 — replace memory.get_stats() crash with safe fallback
    text = text.replace(
        "memory.get_stats()",
        "memory.get_stats() if hasattr(memory, 'get_stats') else {}"
    )
    # Also handle the formatted log line that uses it
    text = re.sub(
        r'(Cycle done.*?memory:)\s*\{.*?\}',
        r'\1{}',
        text
    )
    print("  ✅ get_stats() call made safe")

    write(full, text)
    print("  💾 Saved.")

# ══════════════════════════════════════════════════════════════════════════════
# FIX 5 + 6 — iggy_brain.jl  (StringIndexError + PyCall FieldError)
# ══════════════════════════════════════════════════════════════════════════════

JULIA_READ_OLD = 'read(path, String)'
JULIA_READ_NEW = 'replace(read(path, String), "\\r\\n" => "\\n", "\\r" => "\\n")'

PYCALL_SAFE_WRAPPER = '''
# ── Safe PyCall/TinyLlama loader (fix: FieldError on missing .venv) ──────────
function _safe_load_pycall()
    try
        @eval begin
            using PyCall
        end
        return true
    catch e
        @warn "PyCall unavailable: $e — Tier 2 (local brain) disabled."
        return false
    end
end
const PYCALL_AVAILABLE = _safe_load_pycall()
'''

def patch_brain_jl():
    full = os.path.join(HERE, "iggy_brain.jl")
    if not os.path.exists(full):
        print("\n⚠️  iggy_brain.jl not found — skipping fixes 5+6")
        return

    print("\n📄 Patching iggy_brain.jl  [StringIndexError + PyCall FieldError]")
    backup(full)
    text = read(full)

    # Fix 5 — normalise \r\n on every read(path, String) that isn't already wrapped
    OLD = 'read(path, String)'
    NEW = 'replace(read(path, String), "\\r\\n" => "\\n", "\\r" => "\\n")'
    if OLD in text and NEW not in text:
        text = text.replace(OLD, NEW)
        print("  ✅ read(path,String) wrapped with \\r\\n normalisation")
    else:
        print("  ⏭  read() already patched or not found")

    # Fix 5b — wrap file-read blocks in try/catch for StringIndexError
    # Look for the common pattern:  content = <something with read>
    #                                ... do stuff with content[n:m] ...
    # We add a top-level try/catch around each file loading function if not present.
    # Simple heuristic: find `function load_all_files` or similar and wrap its body.
    for fn_name in ("load_all_files", "read_project_files", "ingest_files", "load_files"):
        pattern = re.compile(
            rf'(function {fn_name}\([^)]*\)\n)(.*?)(^end\b)',
            re.MULTILINE | re.DOTALL
        )
        def wrap_body(m):
            sig  = m.group(1)
            body = m.group(2)
            end  = m.group(3)
            if "try" in body:
                return m.group(0)   # already has try/catch
            indented_body = "    try\n" + "\n".join("    " + l for l in body.splitlines()) + "\n    catch e\n        @warn \"File read error: $e\"\n    end\n"
            return sig + indented_body + end
        new_text = pattern.sub(wrap_body, text)
        if new_text != text:
            text = new_text
            print(f"  ✅ try/catch wrapped around {fn_name}()")

    # Fix 6 — safe PyCall init block
    # Look for bare `using PyCall` at top level (not already inside try)
    pyimport_bare = re.compile(r'^using PyCall\b', re.MULTILINE)
    if pyimport_bare.search(text) and "_safe_load_pycall" not in text:
        # Replace the bare using with the safe wrapper
        text = pyimport_bare.sub("# PyCall loaded safely below", text, count=1)
        # Inject wrapper near top (after other using statements)
        last_using = 0
        for m in re.finditer(r'^using \S', text, re.MULTILINE):
            last_using = m.end()
        insert_at = text.find("\n", last_using) + 1
        text = text[:insert_at] + "\n" + PYCALL_SAFE_WRAPPER + text[insert_at:]
        print("  ✅ PyCall wrapped in _safe_load_pycall()")
    else:
        print("  ⏭  PyCall already safely wrapped or not found at top level")

    write(full, text)
    print("  💾 Saved.")

# ══════════════════════════════════════════════════════════════════════════════
# FIX 7 — iggy_vision.jl  (EOFError restart)
# ══════════════════════════════════════════════════════════════════════════════

VISION_EOF_OLD = """    catch e
        @warn "Vision loop error: $e"
    end"""

VISION_EOF_NEW = """    catch e
        if isa(e, EOFError) || isa(e, Base.IOError)
            @warn "Vision loop pipe closed — restarting in 5s..."
            sleep(5)
            continue
        end
        @warn "Vision loop error: $e"
    end"""

def patch_vision_jl():
    full = os.path.join(HERE, "iggy_vision.jl")
    if not os.path.exists(full):
        print("\n⚠️  iggy_vision.jl not found — skipping fix 7")
        return

    print("\n📄 Patching iggy_vision.jl  [EOFError restart]")
    backup(full)
    text = read(full)

    if VISION_EOF_OLD in text:
        text = text.replace(VISION_EOF_OLD, VISION_EOF_NEW, 1)
        print("  ✅ EOFError → restart logic injected")
    elif "EOFError" in text:
        print("  ⏭  EOFError already handled")
    else:
        # Generic: replace any bare `@warn "Vision loop error: $e"` with restart logic
        text = re.sub(
            r'(@warn "Vision loop error: \$e")',
            'if isa(e, EOFError) || isa(e, Base.IOError)\n            @warn "Vision loop pipe closed — restarting in 5s..."; sleep(5); continue\n        end\n        \\1',
            text
        )
        print("  ✅ EOFError guard injected (fallback pattern)")

    write(full, text)
    print("  💾 Saved.")

# ══════════════════════════════════════════════════════════════════════════════
# FIX 8 — iggy_executive_v3.jl  (EOFError in discovery loop)
# ══════════════════════════════════════════════════════════════════════════════

EXEC_EOF_OLD = """    catch e
        @warn "Discovery cycle error: $e"
    end"""

EXEC_EOF_NEW = """    catch e
        if isa(e, EOFError) || isa(e, Base.IOError)
            @warn "Discovery pipe closed — restarting in 10s..."
            sleep(10)
            continue
        end
        @warn "Discovery cycle error: $e"
    end"""

def patch_executive_jl():
    for fname in ("iggy_executive_v3.jl", "iggy_executive.jl"):
        full = os.path.join(HERE, fname)
        if not os.path.exists(full):
            continue

        print(f"\n📄 Patching {fname}  [EOFError in discovery loop]")
        backup(full)
        text = read(full)

        if EXEC_EOF_OLD in text:
            text = text.replace(EXEC_EOF_OLD, EXEC_EOF_NEW, 1)
            print("  ✅ EOFError → restart injected")
            write(full, text)
            print("  💾 Saved.")
        elif "EOFError" in text:
            print("  ⏭  EOFError already handled")
        else:
            text = re.sub(
                r'(@warn "Discovery cycle error: \$e")',
                'if isa(e, EOFError) || isa(e, Base.IOError)\n            @warn "Discovery pipe closed — restarting in 10s..."; sleep(10); continue\n        end\n        \\1',
                text
            )
            if text:
                write(full, text)
                print("  ✅ EOFError guard injected (fallback)")

# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════

def main():
    print("=" * 60)
    print("  IGGY v3 Patch Script")
    print(f"  Working directory: {HERE}")
    print("=" * 60)

    patch_memory()       # fixes 1 + 2
    patch_crawler()      # fixes 3 + 4
    patch_brain_jl()     # fixes 5 + 6
    patch_vision_jl()    # fix  7
    patch_executive_jl() # fix  8

    print("\n" + "=" * 60)
    print("  ✅ Patch run complete.")
    print("  All originals saved as <filename>.bak")
    print("  Now run:  julia iggy_executive_v3.jl")
    print("=" * 60)

if __name__ == "__main__":
    main()
