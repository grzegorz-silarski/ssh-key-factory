#!/usr/bin/env bash
# Invoke this executable from either Bash or Zsh; the shebang runs it with Bash.
set -euo pipefail

PACKAGE_REPOSITORY="${PACKAGE_REPOSITORY:-https://dl-cdn.alpinelinux.org}"
case "$PACKAGE_REPOSITORY" in
  https://*[!A-Za-z0-9._:/-]*)
    echo "ERROR: PACKAGE_REPOSITORY contains invalid characters." >&2
    exit 1
    ;;
  https://*) ;;
  *)
    echo "ERROR: PACKAGE_REPOSITORY must start with https://" >&2
    exit 1
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
docker build --pull --build-arg "PACKAGE_REPOSITORY=$PACKAGE_REPOSITORY" --tag devops/ssh-keygen:latest "$SCRIPT_DIR"
