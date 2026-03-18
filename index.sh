#!/usr/bin/env bash
set -euo pipefail

# ----------------------
# Logging
# ----------------------
log() { echo "[INFO] $*"; }
err() { echo "[ERROR] $*" >&2; }

trap 'rc=$?; err "exit $rc at line ${BASH_LINENO[0]:-?}: ${BASH_COMMAND:-?}"' ERR
trap 'rc=$?; [ "$rc" -eq 0 ] && log "Done: ${VIDEO_ID:-N/A}.mp4"' EXIT

# ----------------------
# Utils
# ----------------------
command_exists() { command -v "$1" >/dev/null 2>&1; }
add_local_bin_to_path() { export PATH="$HOME/.local/bin:$PATH"; }

detect_pkg_mgr() {
  for m in apt-get brew pacman dnf yum zypper; do
    command_exists "$m" && echo "$m" && return
  done
  return 1
}

sudo_available() { command_exists sudo && sudo -n true 2>/dev/null; }

# ----------------------
# Package Installation
# ----------------------
install_pkg_system() {
  local pkg="$1" mgr
  mgr=$(detect_pkg_mgr) || return 1
  if sudo_available; then
    case "$mgr" in
      apt-get) sudo apt-get update -qq && sudo apt-get install -y -qq "$pkg" ;;
      brew) brew install "$pkg" ;;
      pacman) sudo pacman -Sy --noconfirm "$pkg" ;;
      dnf) sudo dnf install -y "$pkg" ;;
      yum) sudo yum install -y "$pkg" ;;
      zypper) sudo zypper install -y "$pkg" ;;
      *) return 1 ;;
    esac
  else
    return 1
  fi
}

install_pkg_user() {
  local pkg="$1"
  case "$pkg" in
    yt-dlp)
      log "Installing yt-dlp..."
      add_local_bin_to_path
      if command_exists pip3; then pip3 install --user --upgrade yt-dlp
      elif command_exists pip; then pip install --user --upgrade yt-dlp
      else err "pip not found"; return 1; fi
      ;;
    ffmpeg)
      log "Installing ffmpeg (latest static build)..."
      add_local_bin_to_path
      mkdir -p "$HOME/.local/bin" "$HOME/.local/tmp"
      tmpdir=$(mktemp -d "${HOME}/.local/tmp/ffmpeg.XXXX")
      trap 'rm -rf "$tmpdir"' RETURN

      # OS判定
      if [[ "$(uname)" == "Linux" ]]; then
        url=$(curl -fsSL https://johnvansickle.com/ffmpeg/releases/ | grep -oP 'https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz' | head -n1)
      elif [[ "$(uname)" == "Darwin" ]]; then
        url=$(curl -fsSL https://evermeet.cx/ffmpeg/ | grep -oP 'https://evermeet.cx/ffmpeg/ffmpeg-[0-9\.]+\.zip' | head -n1)
      else
        url="https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"
      fi

      curl -fsSL "$url" -o "$tmpdir/ffbuild"

      if file "$tmpdir/ffbuild" | grep -q 'XZ compressed'; then
        tar -xJf "$tmpdir/ffbuild" -C "$tmpdir"
      elif file "$tmpdir/ffbuild" | grep -q 'Zip archive'; then
        unzip -q "$tmpdir/ffbuild" -d "$tmpdir"
      fi

      bin=$(find "$tmpdir" -type f -name ffmpeg* -perm /111 | head -n1)
      [[ -n "$bin" ]] || { err "ffmpeg binary not found"; return 1; }
      cp "$bin" "$HOME/.local/bin/ffmpeg" && chmod +x "$HOME/.local/bin/ffmpeg"
      ;;
    python3|python) err "Install Python via pyenv/asdf"; return 1 ;;
    *) err "No install method for $pkg"; return 1 ;;
  esac
}

install_pkg() {
  install_pkg_system "$1" || install_pkg_user "$1"
}

# ----------------------
# Ensures
# ----------------------
ensure_python() {
  if command_exists python3; then PYTHON=python3
  elif command_exists python; then PYTHON=python
  else log "Installing python3..."; install_pkg python3; PYTHON=python3; fi
}

ensure_pip() {
  if command_exists pip3; then PIP="pip3"
  elif command_exists pip; then PIP="pip"
  else
    log "Bootstrapping pip..."
    "$PYTHON" -m ensurepip --upgrade >/dev/null 2>&1 || curl -fsS https://bootstrap.pypa.io/get-pip.py | "$PYTHON" -
    PIP="$PYTHON -m pip"
  fi
}

ensure_ffmpeg() {
  command_exists ffmpeg || { log "ffmpeg missing, installing..."; install_pkg ffmpeg; }
  command_exists ffmpeg || { err "ffmpeg install failed"; return 1; }
}

ensure_yt_dlp() {
  # 最新版確認
  if command_exists yt-dlp; then
    installed=$("$PIP" show yt-dlp 2>/dev/null | grep Version | awk '{print $2}' || echo "")
    latest=$(curl -fsSL https://pypi.org/pypi/yt-dlp/json | jq -r '.info.version')
    if [[ "$installed" != "$latest" ]]; then
      log "Updating yt-dlp $installed -> $latest"
      $PIP install --user --upgrade yt-dlp
    fi
  else
    log "yt-dlp missing, installing..."
    [[ -n "${PIP:-}" ]] && $PIP install --user --upgrade yt-dlp || install_pkg_user yt-dlp
  fi
  command_exists yt-dlp || { err "yt-dlp not found"; return 1; }
  add_local_bin_to_path
}

# ----------------------
# Video download & remux
# ----------------------
download_video() {
  local url="$1"
  yt-dlp -f "bv*+ba/b" --merge-output-format mp4 -o "${VIDEO_ID}.%(ext)s" "$url"
}

finalize_output() {
  [[ -f "${VIDEO_ID}.mp4" ]] && return 0
  local found
  found=$(ls "${VIDEO_ID}."* 2>/dev/null | grep -E '\.(mp4|mkv|webm|m4a|opus|mp3)$' | head -n1 || true)
  [[ -n "$found" ]] && ffmpeg -y -loglevel error -i "$found" -c copy "${VIDEO_ID}.mp4" || { err "No output file"; return 1; }
}

# ----------------------
# Main
# ----------------------
main() {
  [[ $# -ge 1 ]] || { err "Missing video ID"; exit 2; }
  VIDEO_ID="$1"
  url="https://www.youtube.com/watch?v=${VIDEO_ID}"

  ensure_python
  ensure_pip
  ensure_ffmpeg
  ensure_yt_dlp

  download_video "$url"
  finalize_output
}

main "$@"
