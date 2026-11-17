#!/bin/sh
# SSH Key Factory - generates SSH key pairs (and optionally CA-signed SSH certificates)
# from simple KEY=VALUE configuration files placed in workspace/conf.
#
# Secrets are read from STDIN (line 1: key passphrase, line 2: CA passphrase), never from
# arguments or environment variables, so they do not show up in `ps` or `docker inspect`.
set -euf
umask 077

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ASKPASS="$SCRIPT_DIR/askpass.sh"
WORKSPACE="${SKF_WORKSPACE:-/var/ssh-keygen/workspace}"
CONF_DIR="$WORKSPACE/conf"
KEYS_DIR="$WORKSPACE/keys"
CA_DIR="$WORKSPACE/ca"
CA_KEY="$CA_DIR/ca"
CA_CONF="$CONF_DIR/ca.conf"

MIN_PASSPHRASE_LENGTH=12

: "${REQUEST_NEW_CA_KEY:=false}"
: "${OVERWRITE:=false}"
: "${OVERWRITE_CA:=false}"

KEY_PASS_FILE=""
CA_PASS_FILE=""
CLEANUP_ON_FAILURE=""

log()  { echo "[ssh-key-factory] $*"; }
warn() { echo "[ssh-key-factory] WARNING: $*" >&2; }
die()  { echo "[ssh-key-factory] ERROR: $*" >&2; exit 1; }

is_true() {
  case "$1" in
    true|TRUE|True|yes|YES|Yes|1) return 0 ;;
    *) return 1 ;;
  esac
}

is_bool() {
  case "$1" in
    true|TRUE|True|yes|YES|Yes|1|false|FALSE|False|no|NO|No|0) return 0 ;;
    *) return 1 ;;
  esac
}

on_exit() {
  status=$?
  [ -n "$KEY_PASS_FILE" ] && rm -f "$KEY_PASS_FILE"
  [ -n "$CA_PASS_FILE" ] && rm -f "$CA_PASS_FILE"
  if [ "$status" -ne 0 ] && [ -n "$CLEANUP_ON_FAILURE" ]; then
    rm -rf "$CLEANUP_ON_FAILURE"
    echo "[ssh-key-factory] Partial output removed." >&2
  fi
  exit "$status"
}

# ---------------------------------------------------------------------------
# Runtime environment
# ---------------------------------------------------------------------------

# ssh-keygen refuses to run for a UID without a passwd entry. The image links /etc/passwd
# to /tmp/passwd (tmpfs), so an entry for the caller's UID can be added on a read-only rootfs.
prepare_passwd() {
  if [ -L /etc/passwd ] && [ -f /etc/passwd.base ]; then
    uid=$(id -u); gid=$(id -g)
    cat /etc/passwd.base > /tmp/passwd
    if ! awk -F: -v u="$uid" '$3 == u { found = 1 } END { exit !found }' /etc/passwd.base; then
      echo "keygen:x:$uid:$gid:ssh-key-factory:/tmp:/sbin/nologin" >> /tmp/passwd
    fi
  fi
}

read_secrets() {
  if [ -n "${KEY_PASSPHRASE+x}" ] || [ -n "${CA_PASSPHRASE+x}" ]; then
    die "Passphrases must not be passed as container environment variables (they are visible in 'docker inspect'). Use new-key.sh / New-Key.ps1, which send them via STDIN."
  fi
  key_pass=""; ca_pass=""
  if [ ! -t 0 ]; then
    IFS= read -r key_pass || true
    IFS= read -r ca_pass || true
  fi
  cr=$(printf '\r')
  key_pass=${key_pass%"$cr"}
  ca_pass=${ca_pass%"$cr"}

  check_passphrase "$key_pass" "Key passphrase"
  check_passphrase "$ca_pass" "CA passphrase"

  KEY_PASS_FILE=$(mktemp)
  CA_PASS_FILE=$(mktemp)
  printf '%s' "$key_pass" > "$KEY_PASS_FILE"
  printf '%s' "$ca_pass" > "$CA_PASS_FILE"
  unset key_pass ca_pass
}

check_passphrase() {
  if [ -n "$1" ] && [ "${#1}" -lt "$MIN_PASSPHRASE_LENGTH" ]; then
    die "$2 must be at least $MIN_PASSPHRASE_LENGTH characters long."
  fi
}

# Run a command with SSH_ASKPASS answering every passphrase prompt from the given file.
with_pass() {
  pass_file=$1; shift
  SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force SKF_PASS_FILE="$pass_file" "$@" < /dev/null
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

reset_config() {
  KEY_TYPE="ed25519"
  KEY_BITS=""
  COMMENT=""
  KDF_ROUNDS="100"
  REQUIRE_PASSPHRASE="no"
  EXPORT_PEM="no"
  EXPORT_PPK="yes"
  EXPORT_BASE64="yes"
  SIGN_WITH_CA="no"
  CERT_TYPE="user"
  CERT_IDENTITY=""
  CERT_PRINCIPALS=""
  CERT_VALIDITY=""
  CERT_OPTIONS=""
  CERT_SERIAL=""
}

# Safe KEY=VALUE parser: the config file is never sourced or executed.
load_config() {
  reset_config
  [ -f "$1" ] || die "Configuration $1 not found."
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed=$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    case "$trimmed" in
      ""|"#"*) continue ;;
      *=*) ;;
      *) die "Invalid line in $1 (expected KEY = VALUE)." ;;
    esac
    key=$(printf '%s' "${trimmed%%=*}" | tr -d ' \t')
    value=$(printf '%s' "${trimmed#*=}" | sed -e 's/^[[:space:]]*//' \
      -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/")
    case "$key" in
      KEY_TYPE)           KEY_TYPE=$value ;;
      KEY_BITS)           KEY_BITS=$value ;;
      COMMENT)            COMMENT=$value ;;
      KDF_ROUNDS)         KDF_ROUNDS=$value ;;
      REQUIRE_PASSPHRASE) REQUIRE_PASSPHRASE=$value ;;
      EXPORT_PEM)         EXPORT_PEM=$value ;;
      EXPORT_PPK)         EXPORT_PPK=$value ;;
      EXPORT_BASE64)      EXPORT_BASE64=$value ;;
      SIGN_WITH_CA)       SIGN_WITH_CA=$value ;;
      CERT_TYPE)          CERT_TYPE=$value ;;
      CERT_IDENTITY)      CERT_IDENTITY=$value ;;
      CERT_PRINCIPALS)    CERT_PRINCIPALS=$value ;;
      CERT_VALIDITY)      CERT_VALIDITY=$value ;;
      CERT_OPTIONS)       CERT_OPTIONS=$value ;;
      CERT_SERIAL)        CERT_SERIAL=$value ;;
      *) die "Unknown setting '$key' in $1" ;;
    esac
  done < "$1"
  validate_config "$1"
}

validate_text() {
  # $1 = setting name, $2 = value, $3 = file
  case "$2" in *[![:print:]]*) die "$1 contains non-printable characters in $3" ;; esac
  [ "${#2}" -le 256 ] || die "$1 is longer than 256 characters in $3"
}

validate_cert_option() {
  case "$1" in
    clear|no-agent-forwarding|no-port-forwarding|no-pty|no-user-rc|no-x11-forwarding) ;;
    permit-agent-forwarding|permit-port-forwarding|permit-pty|permit-user-rc|permit-X11-forwarding) ;;
    verify-required|no-touch-required) ;;
    force-command=?*) ;;
    source-address=?*)
      case "${1#source-address=}" in *[!0-9A-Fa-f.:/,]*) die "Invalid source-address in CERT_OPTIONS ($2)" ;; esac ;;
    extension:?*|critical:?*) ;;
    *) die "Unsupported CERT_OPTIONS entry '$1' in $2" ;;
  esac
}

validate_config() {
  f=$1
  case "$KEY_TYPE" in
    ed25519) KEY_BITS="" ;;
    rsa)
      : "${KEY_BITS:=4096}"
      case "$KEY_BITS" in ""|*[!0-9]*) die "KEY_BITS must be a number in $f" ;; esac
      [ "$KEY_BITS" -ge 3072 ] && [ "$KEY_BITS" -le 16384 ] || die "RSA KEY_BITS must be between 3072 and 16384 ($f)"
      ;;
    ecdsa)
      : "${KEY_BITS:=384}"
      case "$KEY_BITS" in 256|384|521) ;; *) die "ECDSA KEY_BITS must be 256, 384 or 521 ($f)" ;; esac
      ;;
    *) die "Unsupported KEY_TYPE '$KEY_TYPE' in $f (use ed25519, ecdsa or rsa)" ;;
  esac

  case "$KDF_ROUNDS" in ""|*[!0-9]*) die "KDF_ROUNDS must be a number in $f" ;; esac
  [ "$KDF_ROUNDS" -ge 16 ] && [ "$KDF_ROUNDS" -le 1000 ] || die "KDF_ROUNDS must be between 16 and 1000 ($f)"

  for b in REQUIRE_PASSPHRASE EXPORT_PEM EXPORT_PPK EXPORT_BASE64 SIGN_WITH_CA; do
    eval "v=\$$b"
    is_bool "$v" || die "$b must be yes or no in $f"
  done

  validate_text COMMENT "$COMMENT" "$f"
  validate_text CERT_IDENTITY "$CERT_IDENTITY" "$f"

  case "$CERT_TYPE" in user|host) ;; *) die "CERT_TYPE must be 'user' or 'host' in $f" ;; esac
  case "$CERT_SERIAL" in *[!0-9]*) die "CERT_SERIAL must be a number in $f" ;; esac
  [ "${#CERT_SERIAL}" -le 18 ] || die "CERT_SERIAL is too large in $f"

  if is_true "$SIGN_WITH_CA"; then
    [ -n "$CERT_PRINCIPALS" ] || die "CERT_PRINCIPALS is required when SIGN_WITH_CA = yes ($f). A certificate without principals is valid for ANY user/host."
    case "$CERT_PRINCIPALS" in
      *[!A-Za-z0-9._@:*,-]*) die "CERT_PRINCIPALS contains invalid characters in $f" ;;
      ,*|*,|*,,*) die "CERT_PRINCIPALS contains an empty entry in $f" ;;
    esac

    if [ -z "$CERT_VALIDITY" ]; then
      if [ "$CERT_TYPE" = "user" ]; then CERT_VALIDITY="+12w"; else CERT_VALIDITY="+52w"; fi
    fi
    case "$CERT_VALIDITY" in
      *[!A-Za-z0-9:+-]*) die "CERT_VALIDITY contains invalid characters in $f" ;;
      *forever*|*always*) die "CERT_VALIDITY must not be unlimited ('always'/'forever') in $f" ;;
    esac

    if [ "$CERT_TYPE" = "host" ] && [ -n "$CERT_OPTIONS" ]; then
      die "CERT_OPTIONS are only supported for user certificates ($f)"
    fi
    for opt in $CERT_OPTIONS; do
      validate_cert_option "$opt" "$f"
    done
  fi
}

# ---------------------------------------------------------------------------
# Key operations
# ---------------------------------------------------------------------------

keygen() {
  # $1 = output file, $2 = passphrase file (may be empty)
  out=$1; pass_file=$2
  set -- -q -t "$KEY_TYPE" -a "$KDF_ROUNDS" -C "$COMMENT" -f "$out"
  if [ -n "$KEY_BITS" ]; then
    set -- "$@" -b "$KEY_BITS"
  fi
  if [ -s "$pass_file" ]; then
    with_pass "$pass_file" ssh-keygen "$@"
  else
    ssh-keygen "$@" -N "" < /dev/null
  fi
}

fingerprints() {
  {
    ssh-keygen -l -E sha256 -f "$1"
    ssh-keygen -lv -E sha256 -f "$1" | tail -n +2
  } > "$2"
}

to_base64() {
  for f in "$@"; do
    if [ -f "$f" ]; then
      base64 < "$f" | tr -d '\n' > "$f.base64"
    fi
  done
}

# Private material stays 0600 (umask 077); public material becomes 0644.
make_public() {
  for f in "$@"; do
    if [ -f "$f" ]; then
      chmod 644 "$f"
    fi
  done
}

random_serial() {
  # 56 random bits -> unique, non-guessable serial usable for revocation (KRL).
  hex=$(od -An -N7 -tx1 /dev/urandom | tr -d ' \n')
  printf '%u' "0x$hex"
}

require_passphrase_if_configured() {
  # $1 = passphrase file, $2 = description, $3 = config file
  if is_true "$REQUIRE_PASSPHRASE" && [ ! -s "$1" ]; then
    die "$3 requires a passphrase (REQUIRE_PASSPHRASE = yes). Provide the $2."
  fi
}

new_ca() {
  load_config "$CA_CONF"
  require_passphrase_if_configured "$CA_PASS_FILE" "CA passphrase (-c)" "$CA_CONF"

  if [ -e "$CA_KEY" ] && ! is_true "$OVERWRITE_CA"; then
    die "CA key $CA_KEY already exists. Replacing it invalidates every certificate it signed. Set OVERWRITE_CA=true if you really want that."
  fi
  mkdir -p "$CA_DIR"
  rm -f "$CA_KEY" "$CA_KEY.pub" "$CA_KEY.pub.base64" "$CA_DIR/ca.fingerprint"

  log "Generating new SSH CA key ($KEY_TYPE${KEY_BITS:+ $KEY_BITS}) in workspace/ca"
  keygen "$CA_KEY" "$CA_PASS_FILE"
  if [ ! -s "$CA_PASS_FILE" ]; then
    warn "The CA private key is NOT encrypted. Anyone who obtains it can log in to every server that trusts this CA."
  fi
  fingerprints "$CA_KEY.pub" "$CA_DIR/ca.fingerprint"
  to_base64 "$CA_KEY.pub"
  make_public "$CA_KEY.pub" "$CA_KEY.pub.base64" "$CA_DIR/ca.fingerprint"
}

new_key() {
  NAME="$1"
  OUT="$KEYS_DIR/$NAME"
  KEY="$OUT/$NAME"
  CONF="$CONF_DIR/$NAME.conf"
  load_config "$CONF"
  : "${COMMENT:=$NAME}"

  require_passphrase_if_configured "$KEY_PASS_FILE" "key passphrase (-p)" "$CONF"
  if is_true "$SIGN_WITH_CA" && [ "$CERT_TYPE" = "host" ] && [ -s "$KEY_PASS_FILE" ]; then
    die "Host keys must not be encrypted (sshd cannot load encrypted host keys). Run without a key passphrase."
  fi
  if is_true "$SIGN_WITH_CA"; then
    [ -f "$CA_KEY" ] || die "CA key $CA_KEY not found (run with REQUEST_NEW_CA_KEY=true or place your own CA key there)."
  fi

  if [ -e "$OUT" ] && ! is_true "$OVERWRITE"; then
    die "Key folder keys/$NAME already exists. Set OVERWRITE=true to replace it."
  fi
  rm -rf "$OUT"
  mkdir -p "$OUT"
  CLEANUP_ON_FAILURE="$OUT"

  log "Generating $KEY_TYPE${KEY_BITS:+ $KEY_BITS} key '$NAME'"
  keygen "$KEY" "$KEY_PASS_FILE"
  if [ ! -s "$KEY_PASS_FILE" ] && ! { is_true "$SIGN_WITH_CA" && [ "$CERT_TYPE" = "host" ]; }; then
    warn "The private key is NOT protected by a passphrase. Use -p for keys used by people."
  fi

  # PKCS#8 PEM private key + PKCS#8 public key (not available for ed25519).
  if is_true "$EXPORT_PEM"; then
    if [ "$KEY_TYPE" = "ed25519" ]; then
      warn "EXPORT_PEM ignored: ed25519 keys cannot be exported to PEM by ssh-keygen."
    else
      cp "$KEY" "$KEY.pem"
      if [ -s "$KEY_PASS_FILE" ]; then
        with_pass "$KEY_PASS_FILE" ssh-keygen -q -p -m PKCS8 -f "$KEY.pem" > /dev/null
      else
        ssh-keygen -q -p -m PKCS8 -P "" -N "" -f "$KEY.pem" < /dev/null > /dev/null
      fi
      ssh-keygen -e -m PKCS8 -f "$KEY.pub" > "$KEY.pub.pem"
    fi
  fi

  # RFC4716 (SSH2 / commercial SSH) public key format.
  ssh-keygen -e -m RFC4716 -f "$KEY.pub" > "$KEY.rfc4716.pub"

  # PuTTY private key (PPK v3, Argon2id-protected when a passphrase is set).
  if is_true "$EXPORT_PPK"; then
    if [ -s "$KEY_PASS_FILE" ]; then
      puttygen "$KEY" --old-passphrase "$KEY_PASS_FILE" --new-passphrase "$KEY_PASS_FILE" -O private -o "$KEY.ppk"
    else
      puttygen "$KEY" -O private -o "$KEY.ppk"
    fi
  fi

  if is_true "$SIGN_WITH_CA"; then
    sign_key
  fi

  fingerprints "$KEY.pub" "$KEY.fingerprint"
  if is_true "$EXPORT_BASE64"; then
    to_base64 "$KEY" "$KEY.pub" "$KEY.pem" "$KEY.ppk" "$KEY-cert.pub"
  fi
  make_public "$KEY.pub" "$KEY.pub.base64" "$KEY.pub.pem" "$KEY.rfc4716.pub" "$KEY.fingerprint" \
    "$KEY-cert.pub" "$KEY-cert.pub.base64" "$KEY-cert.txt" "$OUT/ca.pub"

  CLEANUP_ON_FAILURE=""
  log "$(head -n 1 "$KEY.fingerprint")"
  log "Done. Files written to keys/$NAME/"
}

sign_key() {
  : "${CERT_SERIAL:=$(random_serial)}"
  log "Signing '$NAME' as $CERT_TYPE certificate (principals: $CERT_PRINCIPALS, validity: $CERT_VALIDITY, serial: $CERT_SERIAL)"

  if ssh-keygen -y -P "" -f "$CA_KEY" > /dev/null 2>&1; then
    warn "The CA private key is NOT encrypted. Consider protecting it with a passphrase (see workspace/ca/README.md)."
  fi

  set -- -q -s "$CA_KEY" -I "${CERT_IDENTITY:-$NAME}" -n "$CERT_PRINCIPALS" -V "$CERT_VALIDITY" -z "$CERT_SERIAL"
  if [ "$CERT_TYPE" = "host" ]; then
    set -- "$@" -h
  fi
  for opt in $CERT_OPTIONS; do
    set -- "$@" -O "$opt"
  done

  with_pass "$CA_PASS_FILE" ssh-keygen "$@" "$KEY.pub" || die "Signing failed (wrong or missing CA passphrase? use -c)."
  ssh-keygen -L -f "$KEY-cert.pub" > "$KEY-cert.txt"
  cp "$CA_KEY.pub" "$OUT/ca.pub"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

[ $# -eq 1 ] || die "Usage: <configuration_name>  (name of a file in workspace/conf without .conf)"
NAME="${1%.conf}"
case "$NAME" in
  ""|[.-]*|*[!A-Za-z0-9._-]*) die "Invalid configuration name '$1'" ;;
  ca) die "'ca' is reserved for the CA configuration" ;;
esac
[ "${#NAME}" -le 64 ] || die "Configuration name is longer than 64 characters."
[ -f "$CONF_DIR/$NAME.conf" ] || die "Configuration workspace/conf/$NAME.conf not found."

trap on_exit EXIT
trap 'exit 130' INT TERM

prepare_passwd
read_secrets
mkdir -p "$KEYS_DIR"

if is_true "$REQUEST_NEW_CA_KEY"; then
  # Subshell keeps the CA settings from leaking into the key settings.
  ( new_ca )
fi

new_key "$NAME"
