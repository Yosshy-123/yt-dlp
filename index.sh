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
    local installed latest ni li
    normalize() {
        echo "$1" | tr -d ' \t\r\n' | awk -F. '{out=$1+0; for(i=2;i<=NF;i++){out=out"."($i+0)}; print out}'
    }

    ver_cmp() {
        local a=(${1//./ }) b=(${2//./ })
        local i max
        (( ${#a[@]} > ${#b[@]} )) && max=${#a[@]} || max=${#b[@]}
        for ((i=0;i<max;i++)); do
            local ai=${a[i]:-0} bi=${b[i]:-0}
            if (( ai > bi )); then return 1; fi
            if (( ai < bi )); then return 2; fi
        done
        return 0
    }

    if command_exists yt-dlp; then
        installed=$(yt-dlp --version 2>/dev/null || echo "")
        installed=$(normalize "$installed")
        latest=$(python3 -c "import json,urllib.request as u; print(json.load(u.urlopen('$YT_DLP_PYPI_JSON'))['info']['version'])" 2>/dev/null || echo "")
        latest=$(normalize "$latest")

        if [[ -z "$installed" || -z "$latest" ]]; then
            warn "Could not determine versions (installed='$installed', latest='$latest'); attempting upgrade"
            if python3 -m pip install --user --upgrade yt-dlp >/dev/null 2>&1; then
                log "yt-dlp upgraded (version unknown)"
            else
                err "Failed to upgrade yt-dlp"
                exit 1
            fi
            return
        fi

        ver_cmp "$installed" "$latest"
        case $? in
            0)  ;;
            1)  log "Installed yt-dlp ($installed) is newer than PyPI ($latest); skipping update" ;;
            2)  log "Updating yt-dlp $installed -> $latest"
                if python3 -m pip install --user --upgrade yt-dlp >/dev/null 2>&1; then
                    log "yt-dlp updated to $latest"
                else
                    err "Failed to update yt-dlp"
                    exit 1
                fi
                ;;
        esac
    else
        log "yt-dlp not found, installing latest version..."
        if python3 -m pip install --user yt-dlp >/dev/null 2>&1; then
            latest=$(python3 -c "import json,urllib.request as u; print(json.load(u.urlopen('$YT_DLP_PYPI_JSON'))['info']['version'])" 2>/dev/null || true)
            latest=$(normalize "$latest")
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
