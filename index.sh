#!/usr/bin/env bash
set -euo pipefail

# Silent index.sh
# - Only outputs on error (stderr) or on successful completion (one line to stdout).
# - Usage: ./index.sh "<URL>"

# ---- Traps: error and exit ----
trap 'rc=$?; cmd="${BASH_COMMAND:-unknown}"; lineno=${BASH_LINENO[0]:-?}; echo "ERROR: exit code $rc at line $lineno. Command: \"$cmd\"" >&2' ERR
trap 'rc=$?; if [ "$rc" -eq 0 ]; then
  # On success, print a concise completion message with filename if available.
  if [ -n "${VIDEO_ID:-}" ] && [ -f "${VIDEO_ID}.mp4" ]; then
    echo "Done: ${VIDEO_ID}.mp4"
  elif [ -n "${VIDEO_ID:-}" ]; then
    echo "Done: ${VIDEO_ID}"
  else
    echo "Done."
  fi
fi' EXIT

# ---- Helpers ----
command_exists() { command -v "$1" >/dev/null 2>&1; }

detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt";       return; fi
  if command -v brew >/dev/null 2>&1; then echo "brew";      return; fi
  if command -v pacman >/dev/null 2>&1; then echo "pacman";  return; fi
  if command -v dnf >/dev/null 2>&1; then echo "dnf";        return; fi
  if command -v yum >/dev/null 2>&1; then echo "yum";        return; fi
  if command -v zypper >/dev/null 2>&1; then echo "zypper";  return; fi
  echo ""
}

run_quiet() {
  # run command, keep stderr visible for errors, silence stdout
  "$@" >/dev/null
}

# ---- Ensure Python + pip ----
ensure_python_and_pip() {
  PY_EXE=""
  if command_exists python3; then PY_EXE=python3
  elif command_exists python; then PY_EXE=python
  fi

  if [ -z "$PY_EXE" ]; then
    PKG=$(detect_pkg_mgr)
    if [ -z "$PKG" ]; then
      echo "ERROR: Python not found and no supported package manager detected." >&2
      exit 1
    fi
    case "$PKG" in
      apt) run_quiet sudo apt-get update; run_quiet sudo apt-get install -y python3 python3-venv python3-pip ;;
      brew) run_quiet brew install python ;;
      pacman) run_quiet sudo pacman -Sy --noconfirm python python-pip ;;
      dnf) run_quiet sudo dnf install -y python3 python3-pip ;;
      yum) run_quiet sudo yum install -y python3 python3-pip ;;
      zypper) run_quiet sudo zypper install -y python3 python3-pip ;;
      *) echo "ERROR: unsupported package manager: $PKG" >&2; exit 1 ;;
    esac
    if command_exists python3; then PY_EXE=python3
    elif command_exists python; then PY_EXE=python
    else
      echo "ERROR: Python installation failed." >&2
      exit 1
    fi
  fi

  PIP_EXE=""
  if command_exists pip3; then PIP_EXE=pip3
  elif command_exists pip; then PIP_EXE=pip
  else
    # try ensurepip; suppress stdout
    if "$PY_EXE" -m ensurepip >/dev/null 2>&1 || "$PY_EXE" -m pip --version >/dev/null 2>&1; then
      PIP_EXE="$PY_EXE -m pip"
    else
      # bootstrap pip with get-pip.py (silent)
      if command_exists curl; then
        curl -sS https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py
        "$PY_EXE" /tmp/get-pip.py >/dev/null 2>&1 || true
        rm -f /tmp/get-pip.py
      elif command_exists wget; then
        wget -q -O /tmp/get-pip.py https://bootstrap.pypa.io/get-pip.py
        "$PY_EXE" /tmp/get-pip.py >/dev/null 2>&1 || true
        rm -f /tmp/get-pip.py
      fi
      if command_exists pip3; then PIP_EXE=pip3
      elif command_exists pip; then PIP_EXE=pip
      else
        PIP_EXE="$PY_EXE -m pip"
      fi
    fi
  fi

  PYTHON_EXEC="$PY_EXE"
  PIP_EXEC="$PIP_EXE"
}

# ---- Ensure ffmpeg ----
ensure_ffmpeg() {
  if command_exists ffmpeg; then return; fi
  PKG=$(detect_pkg_mgr)
  if [ -z "$PKG" ]; then
    echo "ERROR: ffmpeg not found and no supported package manager detected." >&2
    exit 1
  fi
  case "$PKG" in
    apt) run_quiet sudo apt-get update; run_quiet sudo apt-get install -y ffmpeg ;;
    brew) run_quiet brew install ffmpeg ;;
    pacman) run_quiet sudo pacman -Sy --noconfirm ffmpeg ;;
    dnf)  run_quiet sudo dnf install -y ffmpeg ;;
    yum)  run_quiet sudo yum install -y epel-release; run_quiet sudo yum install -y ffmpeg ;;
    zypper) run_quiet sudo zypper install -y ffmpeg ;;
    *) echo "ERROR: unsupported package manager: $PKG" >&2; exit 1 ;;
  esac
  command_exists ffmpeg || { echo "ERROR: ffmpeg installation failed." >&2; exit 1; }
}

# ---- Ensure yt-dlp ----
ensure_yt_dlp() {
  if command_exists yt-dlp; then return; fi
  if [ -z "${PIP_EXEC:-}" ]; then
    echo "ERROR: pip is not available to install yt-dlp." >&2
    exit 1
  fi

  # prefer user install; quiet
  if echo "$PIP_EXEC" | grep -q " "; then
    # e.g. "python3 -m pip"
    eval "$PIP_EXEC install --upgrade --user yt-dlp --quiet"
  else
    "$PIP_EXEC" install --upgrade --user yt-dlp --quiet
  fi

  # ensure user-local bin is on PATH for this session
  USER_BIN="$HOME/.local/bin"
  if [ -d "$USER_BIN" ] && ! echo "$PATH" | /bin/grep -q "$USER_BIN"; then
    export PATH="$USER_BIN:$PATH"
  fi

  if ! command_exists yt-dlp; then
    echo "ERROR: yt-dlp installed but not found on PATH. Add $USER_BIN to PATH." >&2
    exit 1
  fi
}

# ---- Main ----
if [ $# -lt 1 ]; then
  echo "ERROR: missing URL argument" >&2
  exit 2
fi

URL="$1"

ensure_python_and_pip
ensure_ffmpeg
ensure_yt_dlp

# determine output template quietly
VIDEO_ID="$(yt-dlp --get-id "$URL" 2>/dev/null || true)"
if [ -n "$VIDEO_ID" ]; then
  OUT_TEMPLATE="${VIDEO_ID}.%(ext)s"
else
  OUT_TEMPLATE="download.%(ext)s"
fi

# perform download silently (yt-dlp -q suppresses progress; errors still go to stderr)
yt-dlp -q --no-progress -f "bv*+ba/b" --merge-output-format mp4 -o "$OUT_TEMPLATE" "$URL"

# normalize output: ensure an mp4 exists or convert silently
if [ -n "${VIDEO_ID:-}" ] && [ -f "${VIDEO_ID}.mp4" ]; then
  : # file exists, exit normally (EXIT trap prints message)
elif [ -n "${VIDEO_ID:-}" ]; then
  # find produced file
  FOUND="$(ls "${VIDEO_ID}."* 2>/dev/null | head -n1 || true)"
  if [ -n "$FOUND" ]; then
    ffmpeg -y -loglevel error -i "$FOUND" -c copy "${VIDEO_ID}.mp4"
  else
    echo "ERROR: no output file found for ${VIDEO_ID}" >&2
    exit 1
  fi
else
  # no video id; try to find the download.* file and convert if necessary
  FOUND="$(ls download.* 2>/dev/null | head -n1 || true)"
  if [ -n "$FOUND" ]; then
    # if already mp4, leave; otherwise try to copy to download.mp4
    case "$FOUND" in
      *.mp4) mv -f "$FOUND" download.mp4 ;;
      *) ffmpeg -y -loglevel error -i "$FOUND" -c copy download.mp4 ;;
    esac
  else
    echo "ERROR: download completed but no output file found." >&2
    exit 1
  fi
fi

# normal exit; EXIT trap will print final one-line success.
exit 0
