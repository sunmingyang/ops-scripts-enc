#!/usr/bin/env bash
set -euo pipefail
IFS=$'
	'

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
  apt-get install -y --no-install-recommends ca-certificates curl tar age python3
}

write_age_key() {
  if [ -z "${AGE_KEY_B64-}" ]; then
    echo "ERROR: AGE_KEY_B64 is required." >&2
    exit 1
  fi

  mkdir -p "$(dirname "$AGE_KEY_FILE")"
  old_umask="$(umask)"
  umask 077
  printf "%s" "$AGE_KEY_B64" | b64_decode > "$AGE_KEY_FILE"
  chmod 600 "$AGE_KEY_FILE"
  umask "$old_umask"
}

raw_base() {
  echo "https://raw.githubusercontent.com/${OWNER}/${ENC_REPO}/${ENC_BRANCH}/${DIST_DIR}"
}

api_latest_name() {
  local api_url json name

  api_url="https://api.github.com/repos/${OWNER}/${ENC_REPO}/contents/${DIST_DIR}/latest.txt?ref=${ENC_BRANCH}"

  # GitHub raw can be cached; API content is the source of truth.
  json="$(curl -fsSL -H 'Accept: application/vnd.github+json' "$api_url")" || return 1

  name="$(printf '%s' "$json" | python3 -c 'import json,sys,base64; j=json.load(sys.stdin); c=j.get("content",""); c="".join(c.split()); print(base64.b64decode(c).decode("utf-8").strip())')" || return 1

  [ -n "$name" ] || return 1
  printf '%s' "$name"
}

download_and_install() {
  local ref_file="${1:-}"
  local base url_latest pkg_name tmp

  base="$(raw_base)"
  tmp="$(mktemp -d)"

  if [ -n "$ref_file" ]; then
    pkg_name="$ref_file"
  else
    # Prefer GitHub API to avoid raw cache staleness; fallback to raw with cache-bust.
    if pkg_name="$(api_latest_name)"; then
      :
    else
      url_latest="${base}/latest.txt?ts=$(date +%s)"
      pkg_name="$(curl -fsSL "$url_latest")"
    fi
  fi

  curl -fsSL -o "$tmp/pkg.age" "${base}/${pkg_name}"
  age -d -i "$AGE_KEY_FILE" -o "$tmp/pkg.tar.gz" "$tmp/pkg.age"

  rm -rf "$INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"
  tar -C "$INSTALL_DIR" -xzf "$tmp/pkg.tar.gz"

  chmod +x "$INSTALL_DIR/bin/"* 2>/dev/null || true
  # Use a wrapper instead of symlink so ops can locate its real bin/ directory.
  cat > "$OPS_LINK" <<'EOF'
#!/usr/bin/env bash
exec /opt/ops-scripts/bin/ops "$@"
EOF
  chmod +x "$OPS_LINK"

  chmod 755 "$INSTALL_DIR" || true

  echo "$pkg_name" > "$INSTALL_DIR/.ops-scripts-package"
  chmod 0644 "$INSTALL_DIR/.ops-scripts-package" || true

  rm -rf "$tmp"

  echo "OK: installed to $INSTALL_DIR"
  echo "OK: ops installed at $OPS_LINK"
  echo "OK: installed package $(cat "$INSTALL_DIR/.ops-scripts-package" 2>/dev/null || true)"
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