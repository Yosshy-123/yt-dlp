#!/usr/bin/env bash
set -euo pipefail

# ----------------------
# Logging
# ----------------------
log()  { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }
err()  { echo "[ERROR] $*" >&2; }

trap 'rc=$?; err "Exit $rc at line ${BASH_LINENO[0]:-?}: ${BASH_COMMAND:-?}"' ERR
trap 'rc=$?; [ "$rc" -eq 0 ] && log "Done: ${VIDEO_ID:-N/A}.mp4"' EXIT

# ----------------------
# Constants
# ----------------------
LOCAL_BIN="$HOME/.local/bin"
export PATH="$LOCAL_BIN:$PATH"

REQUIRED_CMDS=(python3 pip3 ffmpeg)
YT_DLP_PYPI_JSON="https://pypi.org/pypi/yt-dlp/json"

# ----------------------
# Utility functions
# ----------------------
command_exists() { command -v "$1" >/dev/null 2>&1; }

# ----------------------
# Pre-check required commands
# ----------------------
check_required_commands() {
    local missing=()
    for cmd in "${REQUIRED_CMDS[@]}"; do
        ! command_exists "$cmd" && missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        err "Missing required commands: ${missing[*]}"
        exit 1
    fi
}

# ----------------------
# yt-dlp update
# ----------------------
update_yt_dlp() {
    local installed latest
    if command_exists yt-dlp; then
        installed=$(yt-dlp --version | tr -d ' \t\r\n')
        latest=$(python3 -c "import json,sys,urllib.request as u; print(json.load(u.urlopen('$YT_DLP_PYPI_JSON'))['info']['version'])" | tr -d ' \t\r\n')
        if [[ "$installed" != "$latest" ]]; then
            log "Updating yt-dlp $installed -> $latest"
            if python3 -m pip install --user --upgrade yt-dlp >/dev/null 2>&1; then
                log "yt-dlp updated to $latest"
            else
                err "Failed to update yt-dlp"
                exit 1
            fi
        fi
    else
        log "yt-dlp not found, installing latest version..."
        if python3 -m pip install --user yt-dlp >/dev/null 2>&1; then
            latest=$(python3 -c "import json,sys,urllib.request as u; print(json.load(u.urlopen('$YT_DLP_PYPI_JSON'))['info']['version'])" || true)
            log "yt-dlp installed${latest:+ ($latest)}"
        else
            err "Failed to install yt-dlp"
            exit 1
        fi
    fi
}

# ----------------------
# Video download & post-process
# ----------------------
download_video() {
    local url="$1"
    yt-dlp -f "bv*+ba/b" --merge-output-format mp4 -o "${VIDEO_ID}.%(ext)s" "$url"
}

finalize_output() {
    [[ -f "${VIDEO_ID}.mp4" ]] && return 0
    local found
    found=$(ls "${VIDEO_ID}."* 2>/dev/null | grep -E '\.(mp4|mkv|webm|m4a|opus|mp3)$' | head -n1 || true)
    [[ -n "$found" ]] && ffmpeg -y -loglevel error -i "$found" -c copy "${VIDEO_ID}.mp4" \
        || { err "No output file"; exit 1; }
}

# ----------------------
# Main
# ----------------------
main() {
    [[ $# -ge 1 ]] || { err "Missing video ID"; exit 2; }
    VIDEO_ID="$1"
    local url="https://www.youtube.com/watch?v=${VIDEO_ID}"

    check_required_commands
    update_yt_dlp

    download_video "$url"
    finalize_output
}

main "$@"
