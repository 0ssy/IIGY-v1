# ═══════════════════════════════════════════════════════════════
# IGGY VISION — Screen Learning Module
#
# What it does:
#   1. Takes periodic screenshots (cross-platform)
#   2. Sends image to OpenRouter vision model (Gemini Flash — free)
#   3. Extracts useful knowledge: text, prices, charts, apps, code
#   4. Feeds extracted insights into iggy_brain
#   5. Watches specific files/folders for new content
#   6. Auto-reads documents, CSVs, logs it finds
#
# Setup:
#   Linux:  sudo apt install scrot tesseract-ocr
#   Mac:    built-in screencapture command (no install needed)
#   Windows: uses PowerShell screenshot
#
# Single key: OPENROUTER_API_KEY
# ═══════════════════════════════════════════════════════════════

function ensure(pkg)
    try eval(Meta.parse("using $pkg"))
    catch
        @eval import Pkg; Pkg.add(String(pkg))
        eval(Meta.parse("using $pkg"))
    end
end

ensure(:JSON); ensure(:Dates); ensure(:HTTP); ensure(:Base64)
using JSON, Dates, HTTP, Base64

# Include brain if not already loaded
if !isdefined(Main, :absorb_screen_knowledge!)
    if !isdefined(Main, :iggy_think) && isfile("iggy_brain.jl")
        include("iggy_brain.jl")
    end
end

# ─────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────
const VISION_INTERVAL_SEC  = 30          # screenshot every 30s (adjust as needed)
const SCREENSHOT_PATH      = "/tmp/iggy_screen.png"
const VISION_LOG_FILE      = "iggy_vision_log.json"
const WATCHED_EXTENSIONS   = [".csv", ".txt", ".log", ".json", ".md", ".jl", ".py"]
const WATCHED_DIRS         = ["."]       # add more: ["/path/to/charts", "C:/Users/..."]
const MAX_FILE_READ_BYTES  = 8_000       # max bytes to read from a watched file
const VISION_MEMORY_FILE   = "iggy_vision_memory.json"

# Track which files we've already read to avoid re-reading
file_read_timestamps = Dict{String, Float64}()
vision_log = Vector{Dict{String,Any}}()

# ─────────────────────────────────────────
# PLATFORM DETECTION
# ─────────────────────────────────────────
function get_os()
    if Sys.iswindows() return :windows
    elseif Sys.isapple() return :mac
    else return :linux
    end
end

# ─────────────────────────────────────────
# SCREENSHOT
# ─────────────────────────────────────────
function take_screenshot!(path::String = SCREENSHOT_PATH)
    os = get_os()
    try
        if os == :mac
            run(`screencapture -x $path`)
        elseif os == :linux
            # Try scrot first, fall back to import (ImageMagick)
            if success(`which scrot`)
                run(`scrot $path`)
            elseif success(`which import`)
                run(`import -window root $path`)
            elseif success(`which gnome-screenshot`)
                run(`gnome-screenshot -f $path`)
            else
                println("⚠️  No screenshot tool found. Install scrot: sudo apt install scrot")
                return false
            end
        elseif os == :windows
            # PowerShell screenshot
            ps_cmd = """
Add-Type -AssemblyName System.Windows.Forms
\$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
\$bmp = New-Object System.Drawing.Bitmap(\$screen.Width, \$screen.Height)
\$g = [System.Drawing.Graphics]::FromImage(\$bmp)
\$g.CopyFromScreen(\$screen.Location, [System.Drawing.Point]::Empty, \$screen.Size)
\$bmp.Save('$(replace(path, "/" => "\\"))')
"""
            run(`powershell -Command $ps_cmd`)
        end
        return isfile(path)
    catch e
        println("⚠️  Screenshot failed: $e")
        return false
    end
end

# ─────────────────────────────────────────
# READ SCREENSHOT AS BASE64
# ─────────────────────────────────────────
function screenshot_to_base64(path::String = SCREENSHOT_PATH)
    isfile(path) || return ""
    try
        return base64encode(read(path))
    catch e
        println("⚠️  Base64 encode failed: $e")
        return ""
    end
end

# ─────────────────────────────────────────
# VISION ANALYSIS PROMPT
# Tells the model what to extract
# ─────────────────────────────────────────
const VISION_EXTRACT_PROMPT = """
You are IGGY's vision module. Analyze this screenshot and extract:

1. APP CONTEXT: What app or website is open? What is the user doing?
2. TEXT CONTENT: Any important text, numbers, prices, data visible?
3. CHARTS/GRAPHS: If financial charts are visible, what asset, timeframe, and patterns do you see?
4. TRADING SIGNALS: Any price levels, indicators, or market information?
5. KNOWLEDGE: Any new facts, concepts, or processes worth learning?

Format each finding as:
APP: <app name and activity>
TEXT: <important text snippets>
CHART: <chart details if any, else NONE>
TRADING: <trading info if any, else NONE>
LEARN: <key takeaway to remember>

Be concise. Only include what is clearly visible. Skip NONE items."""

# ─────────────────────────────────────────
# PROCESS SCREENSHOT WITH VISION MODEL
# ─────────────────────────────────────────
function process_screenshot!(path::String = SCREENSHOT_PATH)
    b64 = screenshot_to_base64(path)
    isempty(b64) && return

    println("👁️  Analyzing screen...")

    # Call vision model via iggy_brain
    if isdefined(Main, :openrouter_vision_call)
        analysis = openrouter_vision_call(b64, VISION_EXTRACT_PROMPT)
    else
        println("⚠️  iggy_brain not loaded — cannot call vision model")
        return
    end

    if startswith(analysis, "ERROR")
        println("⚠️  Vision error: $analysis")
        return
    end

    println("👁️  Screen content:\n$analysis\n")

    # Log it
    entry = Dict{String,Any}("ts" => string(now()), "analysis" => analysis,
                              "source" => "screenshot")
    push!(vision_log, entry)
    if length(vision_log) > 500; popfirst!(vision_log); end
    save_vision_log!()

    # Feed into brain knowledge
    if isdefined(Main, :absorb_screen_knowledge!)
        absorb_screen_knowledge!(analysis; source = "screen")
    end

    # Check for trading info specifically
    if contains(lowercase(analysis), "chart") || contains(lowercase(analysis), "price") ||
       contains(lowercase(analysis), "trading")
        extract_chart_insights!(analysis)
    end
end

# ─────────────────────────────────────────
# EXTRACT CHART / TRADING INSIGHTS
# ─────────────────────────────────────────
function extract_chart_insights!(analysis::String)
    # Parse CHART and TRADING lines and feed to brain as high-priority
    chart_info = ""
    for line in split(analysis, "\n")
        if startswith(strip(line), "CHART:") || startswith(strip(line), "TRADING:")
            chart_info *= strip(line) * "\n"
        end
    end
    if !isempty(chart_info) && !contains(chart_info, "NONE")
        println("📈 Chart data detected: $chart_info")
        if isdefined(Main, :absorb_screen_knowledge!)
            absorb_screen_knowledge!(chart_info; source = "chart_on_screen")
        end
    end
end

# ─────────────────────────────────────────
# FILE WATCHER — reads new/changed files
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
            # Read tail of large files (most recent content)
            let _r = String(read(path)); _r[thisind(_r, max(1, lastindex(_r)-MAX_FILE_READ_BYTES)):end]; end
        else
            read(path, String)
        end

        println("📂 Reading: $path ($(size) bytes)")

        # Determine context based on extension
        _, ext = splitext(path)
        context = if ext == ".csv"   "CSV data file"
                  elseif ext == ".log" "log file"
                  elseif ext == ".jl"  "Julia source code"
                  elseif ext == ".py"  "Python source code"
                  elseif ext == ".json" "JSON data"
                  else "text file"
                  end

        if isdefined(Main, :absorb_screen_knowledge!)
            absorb_screen_knowledge!(content; source = "file:$(basename(path))")
        end

    catch e
        println("⚠️  Cannot read $path: $e")
    end
end

# ─────────────────────────────────────────
# MANUAL FILE INGESTION (called by user)
# ─────────────────────────────────────────
function iggy_read_file(path::String)
    isfile(path) || (println("File not found: $path"); return)
    println("📖 IGGY reading: $path")
    read_and_learn_file!(path)
end

function iggy_read_url(url::String)
    println("🌐 IGGY fetching: $url")
    try
        res  = HTTP.get(url; readtimeout=15)
        text = String(res.body)
        # Strip HTML tags for cleaner text
        text = replace(text, r"<[^>]+>" => " ")
        text = replace(text, r"\s+" => " ")
        text = first(text, min(length(text), MAX_FILE_READ_BYTES))
        if isdefined(Main, :absorb_screen_knowledge!)
            absorb_screen_knowledge!(text; source = "url:$url")
        end
    catch e
        println("⚠️  URL fetch failed: $e")
    end
end

# ─────────────────────────────────────────
# PERSISTENCE
# ─────────────────────────────────────────
function save_vision_log!()
    try
        open(VISION_LOG_FILE, "w") do f
            JSON.print(f, vision_log[max(1,end-100):end], 2)
        end
    catch; end
end

function load_vision_state!()
    isfile(VISION_MEMORY_FILE) || return
    try
        d = JSON.parsefile(VISION_MEMORY_FILE)
        for (k,v) in get(d, "file_timestamps", Dict())
            file_read_timestamps[k] = Float64(v)
        end
        println("👁️  Vision state loaded.")
    catch; end
end

function save_vision_state!()
    try
        open(VISION_MEMORY_FILE, "w") do f
            JSON.print(f, Dict(
                "file_timestamps" => file_read_timestamps,
                "saved_at"        => string(now())
            ), 2)
        end
    catch; end
end

# ─────────────────────────────────────────
# STATUS DISPLAY
# ─────────────────────────────────────────
function vision_status()
    println("\n── IGGY VISION STATUS ────────────────")
    println("  Screenshots processed: $(length(vision_log))")
    println("  Files tracked:         $(length(file_read_timestamps))")
    println("  Watched dirs:          $(join(WATCHED_DIRS, ", "))")
    println("  Screenshot interval:   $(VISION_INTERVAL_SEC)s")
    if isdefined(Main, :screen_knowledge)
        println("  Screen insights:       $(length(screen_knowledge))")
    end
    println("─────────────────────────────────────\n")
end

# ─────────────────────────────────────────
# MAIN VISION LOOP
# ─────────────────────────────────────────
function run_vision_loop(; screenshot::Bool = true, file_watch::Bool = true,
                           interval::Int = VISION_INTERVAL_SEC)
    load_vision_state!()
    println("👁️  IGGY VISION started")
    println("   Screenshot: $screenshot | File watch: $file_watch | Interval: $(interval)s")

    tick = 0
    while true
        try
            tick += 1

            # File watcher runs every cycle
            if file_watch
                scan_watched_files!()
            end

            # Screenshot runs on interval
            if screenshot && tick % max(1, interval ÷ 5) == 0
                if take_screenshot!()
                    process_screenshot!()
                end
            end

            # Save state periodically
            if tick % 20 == 0
                save_vision_state!()
                save_brain_state!()
            end

        catch e
            println("⚠️  Vision loop error: $e")
        end

        sleep(5)  # base tick = 5 seconds
    end
end

# ─────────────────────────────────────────
# ADD WATCHED DIRECTORY AT RUNTIME
# ─────────────────────────────────────────
function iggy_watch_dir!(path::String)
    isdir(path) || (println("Not a directory: $path"); return)
    push!(WATCHED_DIRS, path)
    println("👁️  Now watching: $path")
end

# ─────────────────────────────────────────
# AUTO-RUN
# ─────────────────────────────────────────
if abspath(PROGRAM_FILE) == @__FILE__
    run_vision_loop()
end


