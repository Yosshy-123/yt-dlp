#!/usr/bin/env bash
# Refactored youtube downloader + encoding helper
set -euo pipefail
IFS=$'\n\t'

# --- traps ---------------------------------------------------------
trap 'rc=$?; cmd="${BASH_COMMAND:-unknown}"; lineno=${BASH_LINENO[0]:-?}; printf "ERROR: exit code %d at line %s. Command: \"%s\"\n" "$rc" "$lineno" "$cmd" >&2' ERR
trap 'rc=$?; if [ "$rc" -eq 0 ]; then if [ -n "${VIDEO_ID:-}" ] && [ -f "${VIDEO_ID}.mp4" ]; then printf "Done: %s.mp4\n" "$VIDEO_ID"; elif [ -n "${VIDEO_ID:-}" ]; then printf "Done: %s\n" "$VIDEO_ID"; else printf "Done.\n"; fi fi' EXIT

# --- logging / helpers --------------------------------------------
log(){ printf "%s\n" "$*"; }
info(){ printf "INFO: %s\n" "$*" >&2; }
err(){ printf "ERROR: %s\n" "$*" >&2; }
command_exists(){ command -v "$1" >/dev/null 2>&1; }

# --- detect package manager ---------------------------------------
detect_pkg_mgr(){
  if command_exists apt-get; then echo "apt"; return; fi
  if command_exists brew; then echo "brew"; return; fi
  if command_exists pacman; then echo "pacman"; return; fi
  if command_exists dnf; then echo "dnf"; return; fi
  if command_exists yum; then echo "yum"; return; fi
  if command_exists zypper; then echo "zypper"; return; fi
  echo ""
}

# --- ensure python & pip ------------------------------------------
ensure_python_and_pip(){
  if command_exists python3; then PYTHON=python3
  elif command_exists python; then PYTHON=python
  else
    PKG=$(detect_pkg_mgr)
    if [ -z "$PKG" ]; then err "Python not found and no supported package manager detected."; return 1; fi
    case "$PKG" in
      apt) sudo apt-get update -y 2>/dev/null || true; sudo apt-get install -y python3 python3-venv python3-pip ;;
      brew) brew install python ;;
      pacman) sudo pacman -Sy --noconfirm python python-pip ;;
      dnf) sudo dnf install -y python3 python3-pip ;;
      yum) sudo yum install -y python3 python3-pip ;;
      zypper) sudo zypper install -y python3 python3-pip ;;
      *) err "unsupported package manager: $PKG"; return 1 ;;
    esac
    if command_exists python3; then PYTHON=python3
    elif command_exists python; then PYTHON=python
    else err "Python installation failed."; return 1
    fi
  fi

  # Ensure pip is available through python -m pip
  if ! "$PYTHON" -m pip --version >/dev/null 2>&1; then
    # try ensurepip or bootstrap
    if "$PYTHON" -m ensurepip >/dev/null 2>&1; then
      :
    else
      if command_exists curl; then
        curl -sS https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py
        "$PYTHON" /tmp/get-pip.py || true
        rm -f /tmp/get-pip.py
      elif command_exists wget; then
        wget -q -O /tmp/get-pip.py https://bootstrap.pypa.io/get-pip.py
        "$PYTHON" /tmp/get-pip.py || true
        rm -f /tmp/get-pip.py
      else
        err "Neither ensurepip nor curl/wget available to bootstrap pip."
        return 1
      fi
    fi
    if ! "$PYTHON" -m pip --version >/dev/null 2>&1; then err "pip installation failed."; return 1; fi
  fi

  PIP_CMD=("$PYTHON" -m pip)
}

# --- ensure ffmpeg ------------------------------------------------
ensure_ffmpeg(){
  if command_exists ffmpeg; then return 0; fi
  PKG=$(detect_pkg_mgr)
  if [ -z "$PKG" ]; then err "ffmpeg not found and no supported package manager detected."; return 1; fi
  case "$PKG" in
    apt) sudo apt-get update -y 2>/dev/null || true; sudo apt-get install -y ffmpeg ;;
    brew) brew install ffmpeg ;;
    pacman) sudo pacman -Sy --noconfirm ffmpeg ;;
    dnf) sudo dnf install -y ffmpeg ;;
    yum) sudo yum install -y epel-release || true; sudo yum install -y ffmpeg || true ;;
    zypper) sudo zypper install -y ffmpeg ;;
    *) err "unsupported package manager: $PKG"; return 1 ;;
  esac
  command_exists ffmpeg || { err "ffmpeg installation failed."; return 1; }
}

# --- ensure yt-dlp ------------------------------------------------
ensure_yt_dlp(){
  if command_exists yt-dlp; then return 0; fi
  info "Installing yt-dlp via pip (user)..."
  "${PIP_CMD[@]}" install --upgrade --user yt-dlp >/dev/null 2>&1 || { err "yt-dlp pip install failed."; return 1; }
  USER_BIN="$HOME/.local/bin"
  if [ -d "$USER_BIN" ]; then
    case ":$PATH:" in
      *":$USER_BIN:"*) : ;;
      *) export PATH="$USER_BIN:$PATH" ;;
    esac
  fi
  command_exists yt-dlp || { err "yt-dlp installed but not found on PATH. Add $USER_BIN to PATH."; return 1; }
}

# --- utilities ----------------------------------------------------
extract_video_id(){
  local input="$1"
  # If URL, try to extract v= or youtu.be
  if [[ "$input" =~ v=([A-Za-z0-9_-]{6,}) ]]; then
    echo "${BASH_REMATCH[1]}"; return
  fi
  if [[ "$input" =~ youtu\.be/([A-Za-z0-9_-]{6,}) ]]; then
    echo "${BASH_REMATCH[1]}"; return
  fi
  # If looks like an ID, return raw
  echo "$input"
}

# --- main ---------------------------------------------------------
usage(){
  cat <<EOF
Usage: $0 <youtube-id-or-url>
Example: $0 dQw4w9WgXcQ
       $0 "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
EOF
}

if [ $# -lt 1 ]; then usage; exit 2; fi
case "$1" in
  -h|--help) usage; exit 0 ;;
esac

INPUT="$1"
VIDEO_ID="$(extract_video_id "$INPUT")"
URL="https://www.youtube.com/watch?v=${VIDEO_ID}"
OUT_TMPL="${VIDEO_ID}.%(ext)s"

info "Using video id: $VIDEO_ID"
ensure_python_and_pip
ensure_ffmpeg
ensure_yt_dlp

# Download best video+audio and prefer merging to mp4
info "Downloading with yt-dlp..."
yt-dlp -f "bv*+ba/best" --merge-output-format mp4 -o "$OUT_TMPL" "$URL"

# find file produced
FOUND="$(ls "${VIDEO_ID}."* 2>/dev/null | head -n1 || true)"
if [ -z "$FOUND" ]; then err "no output file found for ${VIDEO_ID}"; exit 1; fi

# If already mp4, move/rename to standard name
if [[ "$FOUND" == *.mp4 ]]; then
  mv -f "$FOUND" "${VIDEO_ID}.mp4"
  exit 0
fi

# choose encoder: prefer nvenc -> qsv -> vaapi -> libx264
ENC=""
if ffmpeg -hide_banner -encoders 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -q 'h264_nvenc'; then ENC="h264_nvenc"; fi
if [ -z "$ENC" ] && ffmpeg -hide_banner -encoders 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -q 'h264_qsv'; then ENC="h264_qsv"; fi
if [ -z "$ENC" ] && ffmpeg -hide_banner -encoders 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -q 'h264_vaapi'; then ENC="h264_vaapi"; fi
if [ -z "$ENC" ]; then ENC="libx264"; fi

info "Transcoding $FOUND -> ${VIDEO_ID}.mp4 using encoder: $ENC"

case "$ENC" in
  h264_nvenc)
    ffmpeg -y -loglevel error -i "$FOUND" -c:v h264_nvenc -preset fast -rc:v vbr_hq -cq:v 19 -c:a aac -b:a 192k "${VIDEO_ID}.mp4"
    ;;
  h264_qsv)
    ffmpeg -y -loglevel error -i "$FOUND" -c:v h264_qsv -global_quality 23 -c:a aac -b:a 192k "${VIDEO_ID}.mp4"
    ;;
  h264_vaapi)
    VAAPI_DEV="/dev/dri/renderD128"
    if [ ! -e "$VAAPI_DEV" ]; then VAAPI_DEV="/dev/dri/card0"; fi
    if [ -e "$VAAPI_DEV" ]; then
      ffmpeg -y -loglevel error -vaapi_device "$VAAPI_DEV" -i "$FOUND" -vf 'format=nv12,hwupload' -c:v h264_vaapi -qp 20 -c:a aac -b:a 192k "${VIDEO_ID}.mp4"
    else
      ffmpeg -y -loglevel error -i "$FOUND" -c:v libx264 -preset fast -crf 20 -c:a aac -b:a 192k "${VIDEO_ID}.mp4"
    fi
    ;;
  libx264|*)
    ffmpeg -y -loglevel error -i "$FOUND" -c:v libx264 -preset fast -crf 20 -c:a aac -b:a 192k "${VIDEO_ID}.mp4"
    ;;
esac

exit $?
