# ═══════════════════════════════════════════════════════════════
# IGGY VISION — Screen Learning + File Watcher Module v3.0
#
# Split of responsibilities:
#   Julia (this file) → file/folder watcher, document ingestion,
#                       persistence, runtime commands
#   Python (iggy_vision.py) → live screen watching, OCR, activity
#                              detection, ChromaDB feeding
#
# No screenshots. No image uploads. No API calls for vision.
# The screen is watched live by iggy_vision.py (started automatically
# by iggy_brain_py.py when the Python brain initializes).
#
# What this file does:
#   1. Watches folders for new/changed files and auto-reads them
#   2. Feeds file content into IGGY's knowledge base
#   3. Handles manual  read <path>  and  url <link>  commands
#   4. Persists file-read state so it doesn't re-read old files
# ═══════════════════════════════════════════════════════════════

using JSON, Dates, HTTP

# ─────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────

const WATCHED_EXTENSIONS  = [".csv", ".txt", ".log", ".json", ".md", ".jl", ".py"]
const WATCHED_DIRS        = String["."]      # add paths at runtime with iggy_watch_dir!()
const MAX_FILE_READ_BYTES = 8_000
const VISION_MEMORY_FILE  = "iggy_vision_memory.json"
const VISION_LOG_FILE     = "iggy_vision_log.json"
const FILE_SCAN_INTERVAL  = 5               # seconds between file scans

# ─────────────────────────────────────────
# STATE
# ─────────────────────────────────────────

const file_read_timestamps = Dict{String, Float64}()
const vision_log           = Vector{Dict{String,Any}}()

# ─────────────────────────────────────────
# FILE WATCHER
# Scans watched dirs for new or changed files and learns from them
# ─────────────────────────────────────────

function scan_watched_files!()
    for dir in WATCHED_DIRS
        isdir(dir) || continue
        try
            for fname in readdir(dir, join=true)
                isfile(fname) || continue
                _, ext = splitext(fname)
                lowercase(ext) in WATCHED_EXTENSIONS || continue

                mtime = stat(fname).mtime
                last  = get(file_read_timestamps, fname, 0.0)

                if mtime > last
                    file_read_timestamps[fname] = mtime
                    read_and_learn_file!(fname)
                end
            end
        catch e
            println("⚠️  File scan error in $dir: $e")
        end
    end
end

function read_and_learn_file!(path::String)
    try
        size = stat(path).size
        size == 0 && return

        content = if size > MAX_FILE_READ_BYTES
            raw = read(path, String)
            raw[thisind(raw, max(1, lastindex(raw) - MAX_FILE_READ_BYTES)):end]
        else
            read(path, String)
        end

        _, ext = splitext(path)
        kind = Dict(
            ".csv"  => "CSV data",
            ".log"  => "log file",
            ".jl"   => "Julia code",
            ".py"   => "Python code",
            ".json" => "JSON data",
            ".md"   => "markdown document",
        )
        label = get(kind, lowercase(ext), "text file")

        println("📂 IGGY reading $(label): $(basename(path)) ($(size) bytes)")

        # Feed into brain knowledge base
        store_to_knowledge_base(content; source = "file:$(basename(path))")

        # Log the event
        entry = Dict{String,Any}(
            "ts"     => string(now()),
            "source" => path,
            "size"   => size,
            "kind"   => label,
        )
        push!(vision_log, entry)
        length(vision_log) > 500 && popfirst!(vision_log)

    catch e
        println("⚠️  Cannot read $path: $e")
    end
end

# ─────────────────────────────────────────
# MANUAL FILE + URL INGESTION
# Called from the REPL: read <path> / url <link>
# ─────────────────────────────────────────

function iggy_read_file(path::String)
    isfile(path) || (println("File not found: $path"); return)
    println("📖 IGGY learning from: $path")
    read_and_learn_file!(path)
end

function iggy_read_url(url::String)
    println("🌐 IGGY fetching: $url")
    try
        res  = HTTP.get(url; readtimeout=15, status_exception=false)
        res.status == 200 || (println("⚠️  HTTP $(res.status) for $url"); return)
        raw  = String(res.body)
        text = replace(replace(raw, r"<[^>]+>" => " "), r"\s+" => " ")
        text = text[1:min(length(text), MAX_FILE_READ_BYTES)]
        store_to_knowledge_base(text; source = "url:$url")
        println("✅ Learned from $url")
    catch e
        println("⚠️  URL fetch failed: $(typeof(e))")
    end
end

# ─────────────────────────────────────────
# ADD WATCHED DIRECTORY AT RUNTIME
# ─────────────────────────────────────────

function iggy_watch_dir!(path::String)
    isdir(path) || (println("Not a directory: $path"); return)
    path in WATCHED_DIRS && (println("Already watching: $path"); return)
    push!(WATCHED_DIRS, path)
    println("👁  Now watching: $path")
end

# ─────────────────────────────────────────
# PERSISTENCE
# ─────────────────────────────────────────

function load_vision_state!()
    isfile(VISION_MEMORY_FILE) || return
    try
        d = JSON.parsefile(VISION_MEMORY_FILE)
        for (k, v) in get(d, "file_timestamps", Dict())
            file_read_timestamps[k] = Float64(v)
        end
        println("👁  Vision file state loaded ($(length(file_read_timestamps)) files tracked).")
    catch e
        println("⚠️  Vision state load error: $e")
    end
end

function save_vision_state!()
    try
        open(VISION_MEMORY_FILE, "w") do f
            JSON.print(f, Dict(
                "file_timestamps" => file_read_timestamps,
                "saved_at"        => string(now()),
            ), 2)
        end
    catch; end
end

function save_vision_log!()
    try
        open(VISION_LOG_FILE, "w") do f
            JSON.print(f, vision_log[max(1, end-100):end], 2)
        end
    catch; end
end

# ─────────────────────────────────────────
# STATUS
# ─────────────────────────────────────────

function vision_status()
    println("\n── IGGY VISION STATUS ────────────────────────────")
    println("  File watcher   : active")
    println("  Screen watcher : Python (iggy_vision.py) — always on")
    println("  Files tracked  : $(length(file_read_timestamps))")
    println("  Files logged   : $(length(vision_log))")
    println("  Watched dirs   : $(join(WATCHED_DIRS, ", "))")
    println("──────────────────────────────────────────────────\n")
end

# ─────────────────────────────────────────
# MAIN VISION LOOP
# Called by iggy_executive_v3.jl via start_vision()
# Screen watching is already running inside Python —
# this loop handles files only.
# ─────────────────────────────────────────

function run_vision_loop(; file_watch::Bool = true)
    load_vision_state!()

    println("👁  IGGY Vision (Julia) started — file watcher active.")
    println("   Screen watching → Python (iggy_vision.py) already running.")

    tick = 0
    while true
        try
            tick += 1

            if file_watch
                scan_watched_files!()
            end

            # Save state every 2 minutes
            if tick % (120 ÷ FILE_SCAN_INTERVAL) == 0
                save_vision_state!()
                save_vision_log!()
            end

        catch e
            println("⚠️  Vision loop error: $e")
        end

        sleep(FILE_SCAN_INTERVAL)
    end
end

# ─────────────────────────────────────────
# STANDALONE RUN
# ─────────────────────────────────────────

if abspath(PROGRAM_FILE) == @__FILE__
    run_vision_loop()
end
