#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: ./new-key.sh [-p] [-c] <configuration_name>

Options:
  -p  Prompt interactively for the new key's passphrase (recommended for user keys)
  -c  Prompt interactively for the SSH CA passphrase (when signing or creating a CA)

Environment variables:
  KEY_PASSPHRASE      Key passphrase (prefer -p interactively)
  CA_PASSPHRASE       CA passphrase (prefer -c interactively)
  REQUEST_NEW_CA_KEY  true to create a new SSH CA key in workspace/ca first (default: false)
  OVERWRITE           true to replace an existing key in workspace/keys/<name> (default: false)
  OVERWRITE_CA        true to allow replacing an existing CA key when REQUEST_NEW_CA_KEY=true (default: false)
EOF
}

prompt_secret() {
  # $1 = label, $2 = confirm (yes/no)
  local p1="" p2=""
  read -r -s -p "$1: " p1 < /dev/tty
  echo >&2
  if [ "${2:-no}" = "yes" ] && [ -n "$p1" ]; then
    read -r -s -p "Confirm $1: " p2 < /dev/tty
    echo >&2
    if [ "$p1" != "$p2" ]; then
      echo "ERROR: Passphrases do not match." >&2
      return 1
    fi
  fi
  printf '%s' "$p1"
}

PROMPT_KEY=no
PROMPT_CA=no
while getopts ":pch" opt; do
  case "$opt" in
    p) PROMPT_KEY=yes ;;
    c) PROMPT_CA=yes ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

if [ $# -ne 1 ]; then
  usage
  exit 1
fi

KEY_PASS="${KEY_PASSPHRASE:-}"
CA_PASS="${CA_PASSPHRASE:-}"

if [ "$PROMPT_KEY" = "yes" ]; then
  KEY_PASS="$(prompt_secret "Key passphrase (min 12 chars)" yes)"
fi

if [ "$PROMPT_CA" = "yes" ]; then
  confirm_ca=no
  case "${REQUEST_NEW_CA_KEY:-false}" in
    true|TRUE|True|yes|YES|Yes|1) confirm_ca=yes ;;
  esac
  CA_PASS="$(prompt_secret "CA passphrase (min 12 chars)" "$confirm_ca")"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
umask 077
mkdir -p "$SCRIPT_DIR/workspace/keys" "$SCRIPT_DIR/workspace/ca"
chmod 700 "$SCRIPT_DIR/workspace/keys" "$SCRIPT_DIR/workspace/ca"

# Passphrases are piped via STDIN (never via CLI args or container -e variables, which
# would expose them in `ps` or `docker inspect`).
printf '%s\n%s\n' "$KEY_PASS" "$CA_PASS" | docker run --rm -i \
  --network none \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=16m \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --pids-limit 64 \
  --memory 256m \
  --user "$(id -u):$(id -g)" \
  -v "$SCRIPT_DIR/workspace":/var/ssh-keygen/workspace \
  -v "$SCRIPT_DIR/workspace/conf":/var/ssh-keygen/workspace/conf:ro \
  -e REQUEST_NEW_CA_KEY="${REQUEST_NEW_CA_KEY:-false}" \
  -e OVERWRITE="${OVERWRITE:-false}" \
  -e OVERWRITE_CA="${OVERWRITE_CA:-false}" \
  devops/ssh-keygen:latest "$1"
