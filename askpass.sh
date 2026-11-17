#!/bin/sh
# Returns the passphrase stored in the file named by SKF_PASS_FILE.
# Used as SSH_ASKPASS so passphrases never appear on any command line.
[ -n "${SKF_PASS_FILE:-}" ] && [ -f "$SKF_PASS_FILE" ] || exit 1
cat "$SKF_PASS_FILE"
