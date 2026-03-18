#!/usr/bin/env bash
set -euo pipefail

trap 'rc=$?; cmd="${BASH_COMMAND:-unknown}"; lineno=${BASH_LINENO[0]:-?}; echo "ERROR: exit code $rc at line $lineno. Command: \"$cmd\"" >&2' ERR
trap 'rc=$?; if [ "$rc" -eq 0 ]; then
  if [ -n "${VIDEO_ID:-}" ] && [ -f "${VIDEO_ID}.mp4" ]; then
    echo "Done: ${VIDEO_ID}.mp4"
  elif [ -n "${VIDEO_ID:-}" ]; then
    echo "Done: ${VIDEO_ID}"
  else
    echo "Done."
  fi
fi' EXIT

command_exists() { command -v "$1" >/dev/null 2>&1; }

detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt"; return; fi
  if command -v brew >/dev/null 2>&1; then echo "brew"; return; fi
  if command -v pacman >/dev/null 2>&1; then echo "pacman"; return; fi
  if command -v dnf >/dev/null 2>&1; then echo "dnf"; return; fi
  if command -v yum >/dev/null 2>&1; then echo "yum"; return; fi
  if command -v zypper >/dev/null 2>&1; then echo "zypper"; return; fi
  echo ""
}

run_quiet() { "$@" >/dev/null; }

run_privileged() {
  if command_exists sudo; then
    sudo "$@"
  else
    "$@"
  fi
}

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
      apt) run_quiet run_privileged apt-get update; run_quiet run_privileged apt-get install -y python3 python3-venv python3-pip ;;
      brew) run_quiet brew install python ;;
      pacman) run_quiet run_privileged pacman -Sy --noconfirm python python-pip ;;
      dnf) run_quiet run_privileged dnf install -y python3 python3-pip ;;
      yum) run_quiet run_privileged yum install -y python3 python3-pip ;;
      zypper) run_quiet run_privileged zypper install -y python3 python3-pip ;;
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
    if "$PY_EXE" -m ensurepip >/dev/null 2>&1 || "$PY_EXE" -m pip --version >/dev/null 2>&1; then
      PIP_EXE="$PY_EXE -m pip"
    else
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

ensure_ffmpeg() {
  if command_exists ffmpeg; then return; fi
  PKG=$(detect_pkg_mgr)
  if [ -z "$PKG" ]; then
    echo "ERROR: ffmpeg not found and no supported package manager detected." >&2
    exit 1
  fi
  case "$PKG" in
    apt) run_quiet run_privileged apt-get update; run_quiet run_privileged apt-get install -y ffmpeg ;;
    brew) run_quiet brew install ffmpeg ;;
    pacman) run_quiet run_privileged pacman -Sy --noconfirm ffmpeg ;;
    dnf) run_quiet run_privileged dnf install -y ffmpeg ;;
    yum) run_quiet run_privileged yum install -y epel-release; run_quiet run_privileged yum install -y ffmpeg ;;
    zypper) run_quiet run_privileged zypper install -y ffmpeg ;;
    *) echo "ERROR: unsupported package manager: $PKG" >&2; exit 1 ;;
  esac
  command_exists ffmpeg || { echo "ERROR: ffmpeg installation failed." >&2; exit 1; }
}

ensure_yt_dlp() {
  if command_exists yt-dlp; then return; fi
  if [ -z "${PIP_EXEC:-}" ]; then
    echo "ERROR: pip is not available to install yt-dlp." >&2
    exit 1
  fi

  if echo "$PIP_EXEC" | grep -q " "; then
    eval "$PIP_EXEC install --upgrade --user yt-dlp --quiet"
  else
    "$PIP_EXEC" install --upgrade --user yt-dlp --quiet
  fi

  USER_BIN="$HOME/.local/bin"
  if [ -d "$USER_BIN" ] && ! echo "$PATH" | /bin/grep -q "$USER_BIN"; then
    export PATH="$USER_BIN:$PATH"
  fi

  if ! command_exists yt-dlp; then
    echo "ERROR: yt-dlp installed but not found on PATH. Add $USER_BIN to PATH." >&2
    exit 1
  fi
}

if [ $# -lt 1 ]; then
  echo "ERROR: missing video ID" >&2
  exit 2
fi

VIDEO_ID="$1"
URL="https://www.youtube.com/watch?v=${VIDEO_ID}"

ensure_python_and_pip
ensure_ffmpeg
ensure_yt_dlp

yt-dlp -q --no-progress -f "bv*+ba/b" --merge-output-format mp4 -o "${VIDEO_ID}.%(ext)s" "$URL"

if [ -f "${VIDEO_ID}.mp4" ]; then
  :
else
  FOUND="$(ls "${VIDEO_ID}."* 2>/dev/null | head -n1 || true)"
  if [ -n "$FOUND" ]; then
    ffmpeg -y -loglevel error -i "$FOUND" -c copy "${VIDEO_ID}.mp4"
  else
    echo "ERROR: no output file found for ${VIDEO_ID}" >&2
    exit 1
  fi
fi

exit 0
