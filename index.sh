#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

# -------------------- Configuration --------------------
# Set MAX_BYTES to a positive integer (bytes) to enforce a download size cap.
# Default 0 => no cap.
MAX_BYTES=0

# Output filename template used by yt-dlp (keeps extension)
OUTPUT_TEMPLATE="%(id)s.%(ext)s"
MERGE_FORMAT="mp4"

# yt-dlp format selector for highest quality (video + audio)
# This picks best video and best audio and falls back to best single file.
FORMAT_SELECTOR="bestvideo+bestaudio/best"
# -------------------- End configuration --------------------

# -------------------- Logging / helpers --------------------
log(){ printf "INFO: %s\n" "$*" >&2; }
warn(){ printf "WARN: %s\n" "$*" >&2; }
err(){ printf "ERROR: %s\n" "$*" >&2; }
fatal(){ err "$*"; exit 1; }

command_exists(){ command -v "$1" >/dev/null 2>&1; }

human_bytes(){
  # simple human-readable bytes (integer inputs)
  local b=$1
  if [ "$b" -ge 1099511627776 ]; then printf "%.2fT" "$(awk "BEGIN {print $b/1099511627776}")"
  elif [ "$b" -ge 1073741824 ]; then printf "%.2fG" "$(awk "BEGIN {print $b/1073741824}")"
  elif [ "$b" -ge 1048576 ]; then printf "%.2fM" "$(awk "BEGIN {print $b/1048576}")"
  elif [ "$b" -ge 1024 ]; then printf "%.2fK" "$(awk "BEGIN {print $b/1024}")"
  else printf "%dB" "$b"
  fi
}

# -------------------- Dependency checks (fail-fast) --------------------
require_command_or_exit(){
  local cmd="$1" pkg_hint="$2"
  if ! command_exists "$cmd"; then
    fatal "$cmd is required but not found. Install it (example): $pkg_hint"
  fi
}

require_command_or_exit yt-dlp "apt-get install -y yt-dlp  # or pip install --user yt-dlp"
require_command_or_exit ffmpeg "apt-get install -y ffmpeg"
require_command_or_exit ffprobe "apt-get install -y ffmpeg"
require_command_or_exit python3 "apt-get install -y python3"

# -------------------- Traps --------------------
cleanup(){
  # future cleanup placeholder
  :
}
trap 'rc=$?; cmd="${BASH_COMMAND:-unknown}"; lineno=${BASH_LINENO[0]:-?}; printf "ERROR: exit code %d at line %s. Command: \"%s\"\n" "$rc" "$lineno" "$cmd" >&2' ERR
trap 'rc=$?; cleanup; if [ "$rc" -eq 0 ]; then if [ -n "${VIDEO_ID:-}" ] && [ -f "${VIDEO_ID}.mp4" ]; then printf "Done: %s.mp4\n" "$VIDEO_ID"; elif [ -n "${VIDEO_ID:-}" ]; then printf "Done: %s\n" "$VIDEO_ID"; else printf "Done.\n"; fi fi' EXIT

# -------------------- Utilities --------------------
extract_video_id(){
  local input="$1"
  if [[ "$input" =~ v=([A-Za-z0-9_-]{6,}) ]]; then echo "${BASH_REMATCH[1]}"; return; fi
  if [[ "$input" =~ youtu\.be/([A-Za-z0-9_-]{6,}) ]]; then echo "${BASH_REMATCH[1]}"; return; fi
  echo "$input"
}

find_output_file_by_template(){
  local id="$1"
  # look for files beginning with id and any extension
  ls "${id}."* 2>/dev/null | head -n1 || true
}

# -------------------- Main flow --------------------
if [ $# -lt 1 ]; then
  printf "Usage: %s <youtube-id-or-url>\n" "$0" >&2
  exit 2
fi

INPUT="$1"
VIDEO_ID="$(extract_video_id "$INPUT")"
URL="https://www.youtube.com/watch?v=${VIDEO_ID}"

log "Target video id: $VIDEO_ID"
log "URL: $URL"

# Obtain metadata JSON from yt-dlp
log "Fetching metadata (yt-dlp -J)..."
YTDLP_JSON="$(yt-dlp -J --no-warnings "$URL")" || fatal "Failed to fetch metadata from yt-dlp"

# Use python3 to select best video and best audio formats and estimate combined size.
# Selection strategy:
#  - video: prefer highest 'height' then highest 'tbr', fallback to filesize
#  - audio: prefer highest 'abr' then highest 'tbr', fallback to filesize
# Output format: format_ids joined by '+' (e.g. "137+140"), total_estimated_bytes (0 if unknown)
read -r SELECTED_FORMATS ESTIMATED_BYTES <<'PYOUT'
$(python3 - "$YTDLP_JSON" <<'PY' 2>/dev/null
import json,sys
meta = json.loads(sys.stdin.read())
formats = meta.get("formats", [])
# helpers
def safe_int(d,k):
    v = d.get(k)
    if v is None: return None
    try: return int(v)
    except: 
        try: return int(float(v))
        except: return None

best_video = None
best_audio = None
for f in formats:
    vcodec = f.get("vcodec")
    acodec = f.get("acodec")
    if vcodec and vcodec != "none":
        # video candidate
        key = (safe_int(f,"height") or 0, safe_int(f,"tbr") or 0, safe_int(f,"width") or 0)
        if best_video is None:
            best_video = (key, f)
        else:
            if key > best_video[0]:
                best_video = (key, f)
    if acodec and acodec != "none":
        # audio candidate
        key = (safe_int(f,"abr") or 0, safe_int(f,"tbr") or 0)
        if best_audio is None:
            best_audio = (key, f)
        else:
            if key > best_audio[0]:
                best_audio = (key, f)

# fallback: if no audio or video separated, pick best single format
if best_video is None and best_audio is None:
    # choose best overall format entry
    best_overall = None
    for f in formats:
        key = (safe_int(f,"tbr") or 0, safe_int(f,"filesize") or 0)
        if best_overall is None or key > best_overall[0]:
            best_overall = (key, f)
    if best_overall:
        f = best_overall[1]
        fmt_id = f.get("format_id")
        size = safe_int(f,"filesize") or safe_int(f,"filesize_approx") or 0
        print(fmt_id + " " + str(size))
        sys.exit(0)

# build selection ids and size
fmt_ids = []
total_size = 0
def size_of(f):
    return safe_int(f,"filesize") or safe_int(f,"filesize_approx") or 0

if best_video is not None:
    f = best_video[1]
    fmt_ids.append(f.get("format_id"))
    total_size += size_of(f)
if best_audio is not None:
    f = best_audio[1]
    # avoid duplicate format_id if same format contains both
    if f.get("format_id") not in fmt_ids:
        fmt_ids.append(f.get("format_id"))
        total_size += size_of(f)

if len(fmt_ids)==0:
    print("" + " 0")
else:
    print("+".join(fmt_ids) + " " + str(total_size))
PY
)
PYOUT

# If python parsing failed for any reason, check variables
if [ -z "${SELECTED_FORMATS:-}" ]; then
  fatal "Failed to select formats. Aborting."
fi

SELECTED_FORMATS="${SELECTED_FORMATS//[$'\t\r\n ']}"  # trim
ESTIMATED_BYTES="${ESTIMATED_BYTES//[$'\t\r\n ']}"    # trim

if [ -z "$SELECTED_FORMATS" ]; then
  fatal "No format selection produced by metadata parser."
fi

if [ -z "$ESTIMATED_BYTES" ]; then
  ESTIMATED_BYTES=0
fi

# Convert ESTIMATED_BYTES to integer safely (bash arithmetic)
case "$ESTIMATED_BYTES" in
  ''|*[!0-9]*)
    ESTIMATED_BYTES=0
    ;;
esac

log "Selected format ids: $SELECTED_FORMATS"
if [ "$ESTIMATED_BYTES" -gt 0 ]; then
  log "Estimated combined download size: $(human_bytes "$ESTIMATED_BYTES") ($ESTIMATED_BYTES bytes)"
else
  log "Estimated combined download size: unknown"
fi

# Enforce data cap if configured
if [ "$MAX_BYTES" -gt 0 ]; then
  if [ "$ESTIMATED_BYTES" -eq 0 ]; then
    fatal "Data cap is set to $(human_bytes "$MAX_BYTES") but estimated download size is unknown. Aborting to avoid unexpected data usage. Set MAX_BYTES=0 to bypass."
  fi
  if [ "$ESTIMATED_BYTES" -gt "$MAX_BYTES" ]; then
    fatal "Estimated download size $(human_bytes "$ESTIMATED_BYTES") exceeds configured data cap $(human_bytes "$MAX_BYTES"). Aborting."
  fi
  log "Estimated size is within data cap $(human_bytes "$MAX_BYTES")."
fi

# Build yt-dlp invocation: always bestvideo+bestaudio/best, force mp4 merge
YTDLP_ARGS=(-f "$FORMAT_SELECTOR" --merge-output-format "$MERGE_FORMAT" -o "$OUTPUT_TEMPLATE" "$URL")

log "Starting download (yt-dlp)..."
yt-dlp "${YTDLP_ARGS[@]}"

# Locate produced file (prefer id.mp4)
MERGED="${VIDEO_ID}.${MERGE_FORMAT}"
if [ -f "$MERGED" ]; then
  FOUND="$MERGED"
else
  FOUND="$(find_output_file_by_template "$VIDEO_ID")"
fi

if [ -z "$FOUND" ]; then
  fatal "No output file found for ${VIDEO_ID} after yt-dlp run."
fi

log "Found output file: $FOUND"

# Verify whether video stream exists (handle audio-only inputs)
HAS_VIDEO_COUNT=$(ffprobe -v error -select_streams v -show_entries stream=codec_type -of csv=p=0 "$FOUND" | wc -l || true)
if [ "$HAS_VIDEO_COUNT" -eq 0 ]; then
  log "Downloaded file appears to be audio-only."
  if [ "$FOUND" != "$MERGED" ]; then
    log "Renaming $FOUND -> $MERGED"
    mv -f "$FOUND" "$MERGED"
    FOUND="$MERGED"
  fi
else
  log "Video stream present in the output."
fi

# Final report
FILE_SIZE_BYTES=$(stat -c%s "$FOUND" 2>/dev/null || stat -f%z "$FOUND" 2>/dev/null || echo 0)
log "Final file: $FOUND ($(human_bytes "$FILE_SIZE_BYTES"))"

exit 0
