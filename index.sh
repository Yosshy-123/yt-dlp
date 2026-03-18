#!/usr/bin/env bash
set -euo pipefail

readonly RATE_LIMIT="1M"

log() { echo "[INFO] $*"; }
err() { echo "[ERROR] $*" >&2; }

trap 'rc=$?; err "exit $rc at line ${BASH_LINENO[0]:-?}: ${BASH_COMMAND:-?}"' ERR
trap 'rc=$?; [ "$rc" -eq 0 ] && log "Done: ${VIDEO_ID:-N/A}.mp4"' EXIT

command_exists() { command -v "$1" >/dev/null 2>&1; }

detect_pkg_mgr() {
  for m in apt-get brew pacman dnf yum zypper; do
    command_exists "$m" && { echo "$m"; return; }
  done
}

install_pkg() {
  local pkg="$1"
  local mgr
  mgr=$(detect_pkg_mgr) || { err "No package manager"; exit 1; }

  case "$mgr" in
    apt-get) sudo apt-get update -qq && sudo apt-get install -y -qq "$pkg" ;;
    brew) brew install "$pkg" ;;
    pacman) sudo pacman -Sy --noconfirm "$pkg" ;;
    dnf) sudo dnf install -y "$pkg" ;;
    yum) sudo yum install -y "$pkg" ;;
    zypper) sudo zypper install -y "$pkg" ;;
    *) err "Unsupported package manager: $mgr"; exit 1 ;;
  esac
}

ensure_python() {
  if command_exists python3; then
    PYTHON=python3
  elif command_exists python; then
    PYTHON=python
  else
    log "Installing Python..."
    install_pkg python3
    PYTHON=python3
  fi
}

ensure_pip() {
  if command_exists pip3; then
    PIP="pip3"
  elif command_exists pip; then
    PIP="pip"
  else
    log "Bootstrapping pip..."
    "$PYTHON" -m ensurepip --upgrade >/dev/null 2>&1 || {
      curl -sS https://bootstrap.pypa.io/get-pip.py | "$PYTHON"
    }
    PIP="$PYTHON -m pip"
  fi
}

ensure_ffmpeg() {
  command_exists ffmpeg || {
    log "Installing ffmpeg..."
    install_pkg ffmpeg
  }
}

ensure_yt_dlp() {
  if command_exists yt-dlp; then return; fi

  log "Installing yt-dlp..."
  $PIP install --user --upgrade yt-dlp >/dev/null

  export PATH="$HOME/.local/bin:$PATH"

  command_exists yt-dlp || {
    err "yt-dlp not found in PATH"
    exit 1
  }
}

download_video() {
  local url="$1"

  yt-dlp \
    -f "bv*+ba/b" \
    --merge-output-format mp4 \
    -o "${VIDEO_ID}.%(ext)s" \
    --limit-rate "$RATE_LIMIT" \
    --external-downloader ffmpeg \
    --downloader-args "ffmpeg:-hwaccel cuda -c:v h264_nvenc" \
    "$url"
}

finalize_output() {
  if [[ -f "${VIDEO_ID}.mp4" ]]; then
    return
  fi

  local found
  found=$(ls "${VIDEO_ID}."* 2>/dev/null | head -n1 || true)

  if [[ -n "$found" ]]; then
    log "Remuxing to mp4..."
    ffmpeg -y -loglevel error -hwaccel cuda -i "$found" -c copy "${VIDEO_ID}.mp4"
  else
    err "No output file found"
    exit 1
  fi
}

main() {
  [[ $# -ge 1 ]] || { err "Missing video ID"; exit 2; }

  VIDEO_ID="$1"
  local url="https://www.youtube.com/watch?v=${VIDEO_ID}"

  ensure_python
  ensure_pip
  ensure_ffmpeg
  ensure_yt_dlp

  download_video "$url"
  finalize_output
}

main "$@"
