#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# --- traps ---------------------------------------------------------
trap 'rc=$?; cmd="${BASH_COMMAND:-unknown}"; lineno=${BASH_LINENO[0]:-?}; printf "ERROR: exit code %d at line %s. Command: \"%s\"\n" "$rc" "$lineno" "$cmd" >&2' ERR
trap 'rc=$?; if [ "$rc" -eq 0 ]; then if [ -n "${VIDEO_ID:-}" ] && [ -f "${VIDEO_ID}.mp4" ]; then printf "Done: %s.mp4\n" "$VIDEO_ID"; elif [ -n "${VIDEO_ID:-}" ]; then printf "Done: %s\n" "$VIDEO_ID"; else printf "Done.\n"; fi fi' EXIT

# --- helpers ------------------------------------------------------
log(){ printf "%s\n" "$*"; }
info(){ printf "INFO: %s\n" "$*" >&2; }
err(){ printf "ERROR: %s\n" "$*" >&2; }
command_exists(){ command -v "$1" >/dev/null 2>&1; }

detect_pkg_mgr(){
  if command_exists apt-get; then echo "apt"; return; fi
  if command_exists brew; then echo "brew"; return; fi
  if command_exists pacman; then echo "pacman"; return; fi
  if command_exists dnf; then echo "dnf"; return; fi
  if command_exists yum; then echo "yum"; return; fi
  if command_exists zypper; then echo "zypper"; return; fi
  echo ""
}

run_privileged(){ if command_exists sudo; then sudo "$@"; else "$@"; fi }

ensure_python_and_pip(){
  if command_exists python3; then PYTHON=python3
  elif command_exists python; then PYTHON=python
  else
    PKG=$(detect_pkg_mgr)
    case "$PKG" in
      apt) run_privileged apt-get update -y 2>/dev/null || true; run_privileged apt-get install -y python3 python3-venv python3-pip ;;
      brew) brew install python ;;
      pacman) run_privileged pacman -Sy --noconfirm python python-pip ;;
      dnf) run_privileged dnf install -y python3 python3-pip ;;
      yum) run_privileged yum install -y python3 python3-pip ;;
      zypper) run_privileged zypper install -y python3 python3-pip ;;
      *) err "Python not found and unsupported package manager"; exit 1 ;;
    esac
    if command_exists python3; then PYTHON=python3
    elif command_exists python; then PYTHON=python
    else err "Python installation failed"; exit 1
    fi
  fi
  PIP_CMD=("$PYTHON" -m pip)
}

ensure_ffmpeg(){
  if command_exists ffmpeg; then return; fi
  PKG=$(detect_pkg_mgr)
  case "$PKG" in
    apt) run_privileged apt-get update -y 2>/dev/null || true; run_privileged apt-get install -y ffmpeg ;;
    brew) brew install ffmpeg ;;
    pacman) run_privileged pacman -Sy --noconfirm ffmpeg ;;
    dnf) run_privileged dnf install -y ffmpeg ;;
    yum) run_privileged yum install -y epel-release || true; run_privileged yum install -y ffmpeg ;;
    zypper) run_privileged zypper install -y ffmpeg ;;
    *) err "ffmpeg not found and unsupported package manager"; exit 1 ;;
  esac
  command_exists ffmpeg || { err "ffmpeg installation failed"; exit 1; }
}

ensure_yt_dlp(){
  if command_exists yt-dlp; then return; fi
  info "Installing yt-dlp..."
  "${PIP_CMD[@]}" install --upgrade --user yt-dlp >/dev/null 2>&1
  USER_BIN="$HOME/.local/bin"
  [[ ":$PATH:" != *":$USER_BIN:"* ]] && export PATH="$USER_BIN:$PATH"
  command_exists yt-dlp || { err "yt-dlp installed but not in PATH"; exit 1; }
}

extract_video_id(){
  local input="$1"
  if [[ "$input" =~ v=([A-Za-z0-9_-]{6,}) ]]; then echo "${BASH_REMATCH[1]}"; return; fi
  if [[ "$input" =~ youtu\.be/([A-Za-z0-9_-]{6,}) ]]; then echo "${BASH_REMATCH[1]}"; return; fi
  echo "$input"
}

usage(){
  cat <<EOF
Usage: $0 <youtube-id-or-url>
EOF
}

if [ $# -lt 1 ]; then usage; exit 2; fi
case "$1" in -h|--help) usage; exit 0 ;; esac

INPUT="$1"
VIDEO_ID="$(extract_video_id "$INPUT")"
URL="https://www.youtube.com/watch?v=${VIDEO_ID}"

info "Using video id: $VIDEO_ID"

ensure_python_and_pip
ensure_ffmpeg
ensure_yt_dlp

# --- download ---
info "Downloading with yt-dlp..."
yt-dlp -f "bv*+ba/best" --merge-output-format mp4 -o "${VIDEO_ID}.%(ext)s" "$URL"

# --- find merged or fallback ---
MERGED="${VIDEO_ID}.mp4"
if [ -f "$MERGED" ]; then
    FOUND="$MERGED"
else
    FOUND="$(ls "${VIDEO_ID}."* 2>/dev/null | head -n1 || true)"
fi

if [ -z "$FOUND" ]; then err "no output file found"; exit 1; fi

# --- check for video stream ---
HAS_VIDEO=$(ffprobe -v error -select_streams v -show_entries stream=codec_type -of csv=p=0 "$FOUND" | wc -l)
if [[ "$HAS_VIDEO" -eq 0 ]]; then
    info "Audio-only file detected, keeping as $MERGED"
    [[ "$FOUND" != "$MERGED" ]] && mv -f "$FOUND" "$MERGED"
    exit 0
fi

# --- choose encoder ---
ENC=""
for E in h264_nvenc h264_qsv h264_vaapi libx264; do
    if ffmpeg -hide_banner -encoders 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -q "$E"; then
        ENC="$E"
        break
    fi
done
[[ -z "$ENC" ]] && ENC="libx264"

info "Transcoding $FOUND -> $MERGED using $ENC"

case "$ENC" in
  h264_nvenc)
    ffmpeg -y -loglevel error -i "$FOUND" -c:v h264_nvenc -preset fast -rc:v vbr_hq -cq:v 19 -c:a aac -b:a 192k "$MERGED"
    ;;
  h264_qsv)
    ffmpeg -y -loglevel error -i "$FOUND" -c:v h264_qsv -global_quality 23 -c:a aac -b:a 192k "$MERGED"
    ;;
  h264_vaapi)
    VAAPI_DEV="/dev/dri/renderD128"
    [[ ! -e "$VAAPI_DEV" ]] && VAAPI_DEV="/dev/dri/card0"
    if [ -e "$VAAPI_DEV" ]; then
        ffmpeg -y -loglevel error -vaapi_device "$VAAPI_DEV" -i "$FOUND" -vf 'format=nv12,hwupload' -c:v h264_vaapi -qp 20 -c:a aac -b:a 192k "$MERGED"
    else
        ffmpeg -y -loglevel error -i "$FOUND" -c:v libx264 -preset fast -crf 20 -c:a aac -b:a 192k "$MERGED"
    fi
    ;;
  libx264|*)
    ffmpeg -y -loglevel error -i "$FOUND" -c:v libx264 -preset fast -crf 20 -c:a aac -b:a 192k "$MERGED"
    ;;
esac

exit 0
