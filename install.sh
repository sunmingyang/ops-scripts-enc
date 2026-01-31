#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

OWNER="sunmingyang"
ENC_REPO="ops-scripts-enc"
ENC_BRANCH="main"
DIST_DIR="dist"

INSTALL_DIR="/opt/ops-scripts"
OPS_LINK="/usr/local/bin/ops"
AGE_KEY_FILE="/root/.config/ops-scripts/age.key"

usage() {
  cat <<'EOF'
Usage:
  install.sh [--install-dir DIR] [--ref FILE]

Env:
  AGE_KEY_B64   (required) base64 of age identity file (AGE-SECRET-KEY-...)
EOF
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: please run as root (sudo)." >&2
    exit 1
  fi
}

b64_decode() {
  # macOS base64 differs from GNU base64; accept both.
  if base64 -d >/dev/null 2>&1 <<<"Zg=="; then
    base64 -d
  else
    base64 --decode
  fi
}

ensure_deps_apt() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends ca-certificates curl tar age
}

write_age_key() {
  if [ -z "${AGE_KEY_B64-}" ]; then
    echo "ERROR: AGE_KEY_B64 is required." >&2
    exit 1
  fi

  mkdir -p "$(dirname "$AGE_KEY_FILE")"
  umask 077
  printf "%s" "$AGE_KEY_B64" | b64_decode > "$AGE_KEY_FILE"
  chmod 600 "$AGE_KEY_FILE"
}

raw_base() {
  echo "https://raw.githubusercontent.com/${OWNER}/${ENC_REPO}/${ENC_BRANCH}/${DIST_DIR}"
}

download_and_install() {
  local ref_file="${1:-}"
  local base url_latest pkg_name tmp

  base="$(raw_base)"
  tmp="$(mktemp -d)"

  if [ -n "$ref_file" ]; then
    pkg_name="$ref_file"
  else
    url_latest="${base}/latest.txt"
    pkg_name="$(curl -fsSL "$url_latest")"
  fi

  curl -fsSL -o "$tmp/pkg.age" "${base}/${pkg_name}"
  age -d -i "$AGE_KEY_FILE" -o "$tmp/pkg.tar.gz" "$tmp/pkg.age"

  rm -rf "$INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"
  tar -C "$INSTALL_DIR" -xzf "$tmp/pkg.tar.gz"

  chmod +x "$INSTALL_DIR/bin/"* 2>/dev/null || true
  ln -sf "$INSTALL_DIR/bin/ops" "$OPS_LINK"

  rm -rf "$tmp"

  echo "OK: installed to $INSTALL_DIR"
  echo "OK: ops linked at $OPS_LINK"
  echo "Try: ops list"
}

main() {
  need_root

  local ref_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --install-dir) INSTALL_DIR="$2"; shift 2 ;;
      --ref) ref_file="$2"; shift 2 ;;
      *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
    esac
  done

  if command -v apt-get >/dev/null 2>&1; then
    ensure_deps_apt
  else
    echo "ERROR: only apt-based distros are supported by this installer right now." >&2
    exit 1
  fi

  write_age_key
  download_and_install "$ref_file"
}

main "$@"
