# Configuration files

Every `<name>.conf` file in this folder describes one SSH key to generate. Run

``` bash
./new-key.sh [-p] [-c] <name>                      # Bash
pwsh ./New-Key.ps1 [-PromptPassphrase] [-PromptCaPassphrase] <name>  # PowerShell Core
```

and all output files are written to `workspace/keys/<name>/`.

To create a new key, copy one of the examples below, rename it (letters, digits, `.`, `_` and `-` only; cannot start with `.` or `-`, max 64 characters) and adjust the values.

## Files in this folder

| File              | Purpose                                                                                                                                                                                                                             |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ca.conf`         | **Reserved.** Settings for the SSH Certificate Authority (CA) key. Used only when you run with `REQUEST_NEW_CA_KEY=true`. The CA key is written to `workspace/ca/ca` (private) and `ca.pub` (public). Requires a passphrase (`-c`). |
| `example.conf`    | Plain **Ed25519** key pair with no certificate. A good default for Git deploy keys, CI/CD access or personal keys.                                                                                                                   |
| `legacy-rsa.conf` | **RSA 4096** key pair for older systems or appliances that don't support Ed25519. Sets `EXPORT_PEM = yes` to also produce PKCS#8 `.pem` (private) and `.pub.pem` (public) files.                                                    |
| `user-cert.conf`  | Ed25519 key **signed by the CA as a user certificate**. Lets user `jane` / `deploy` log in to any server that trusts the CA, without adding the key to `authorized_keys`. Enforces a passphrase (`-p`) and disables `.base64` export. |
| `host-cert.conf`  | Ed25519 key **signed by the CA as a host certificate** for `server01.example.com`. Clients that trust the CA accept the server without a "host key verification" prompt.                                                           |

> [!NOTE]
> Signed keys (`SIGN_WITH_CA = yes`) need a CA key in `workspace/ca`. Create one with `REQUEST_NEW_CA_KEY=true ./new-key.sh -p -c user-cert`, or place your own key there (see [workspace/ca/README.md](../ca/README.md)).

## Which one should I use?

### Interactive SSH terminal sessions (a person logging in to a server)

**Recommended: `user-cert.conf`** if your team runs an SSH CA, otherwise **`example.conf`** (with `REQUIRE_PASSPHRASE = yes`). In both cases use **Ed25519** and **always set a passphrase** (`-p`).

| Situation                                              | Use               | Why                                                                                                                                                                                         |
| ------------------------------------------------------ | ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Team / many servers, CA trusted by `sshd` (**best**)   | `user-cert.conf`  | No `authorized_keys` to manage on every server. Access expires automatically (`CERT_VALIDITY`) and is limited to the listed `CERT_PRINCIPALS`. Interactive shells (`permit-pty`) are allowed. |
| A few servers, no CA                                   | `example.conf`    | Simple Ed25519 key: fast, small, and secure by modern standards. Add the `.pub` file to `~/.ssh/authorized_keys` on the server.                                                           |
| Old server or appliance that rejects Ed25519           | `legacy-rsa.conf` | Use only when Ed25519 isn't supported (e.g. OpenSSH older than 6.5 or some network devices).                                                                                                 |
| Windows users with PuTTY / WinSCP                      | any of the above  | Use the generated `<name>.ppk` file instead of the OpenSSH private key.                                                                                                                     |

Tips for terminal-session keys:

- **Protect the private key with a passphrase** (`./new-key.sh -p ...`, minimum 12 characters), and load it once per session with `ssh-agent` / `ssh-add` (or the macOS Keychain) so you don't have to type it on every connection.
- **One key per person, per device.** Never share a terminal-session key between people. That way you can revoke one laptop without affecting anyone else.
- For user certificates, keep `CERT_VALIDITY` short (default `+12w`; `+1d` to `+12w` recommended). Set `CERT_PRINCIPALS` to the person's own login name(s) and `CERT_IDENTITY` to their e-mail address, so `sshd` logs show who logged in.
- Leave `no-agent-forwarding` in `CERT_OPTIONS` unless the user really needs to hop between servers. Prefer `ssh -J` (ProxyJump) for that.

Example: interactive login key for Jane, valid for 12 weeks:

``` ini
# workspace/conf/jane-laptop.conf
KEY_TYPE           = ed25519
COMMENT            = "jane.doe@example.com (laptop)"
REQUIRE_PASSPHRASE = yes
EXPORT_BASE64      = no
SIGN_WITH_CA       = yes
CERT_TYPE          = user
CERT_IDENTITY      = "jane.doe@example.com"
CERT_PRINCIPALS    = "jane"
CERT_VALIDITY      = +12w
CERT_OPTIONS       = "no-x11-forwarding no-agent-forwarding"
```

``` bash
./new-key.sh -p -c jane-laptop
# then on Jane's machine:
cp workspace/keys/jane-laptop/jane-laptop workspace/keys/jane-laptop/jane-laptop-cert.pub ~/.ssh/
ssh-add ~/.ssh/jane-laptop
ssh jane@server01.example.com
```

### Other uses

| Use case                                   | Use                                                                  |
| ------------------------------------------ | -------------------------------------------------------------------- |
| Git deploy key, CI/CD pipeline, automation | `example.conf` (store the `.base64` file as a pipeline secret)       |
| Server host key that clients trust via CA  | `host-cert.conf` (run `./new-key.sh -c host-cert` without `-p`)      |
| Creating / rotating the CA itself          | `ca.conf` (with `REQUEST_NEW_CA_KEY=true` and `-c`)                  |

## File format

- One `KEY = VALUE` setting per line. Spaces around `=` are optional.
- Values may be wrapped in `"double"` or `'single'` quotes.
- Lines starting with `#` are comments. Comments at the end of a line are **not** supported (`#` would become part of the value).
- Unknown settings are rejected with an error, so typos are caught early.
- The file is parsed with `set -f` (no globbing) and never executed, so shell syntax such as `$VAR`, `*`, or `$(...)` is never expanded.

## Settings

### Key settings

| Setting              | Default    | Allowed values / description                                                                                                          |
| -------------------- | ---------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `KEY_TYPE`           | `ed25519`  | `ed25519` (recommended), `ecdsa`, `rsa`                                                                                               |
| `KEY_BITS`           | depends    | `rsa`: `3072`..`16384` (default `4096`). `ecdsa`: `256`, `384` (default) or `521`. Ignored for `ed25519`.                             |
| `KDF_ROUNDS`         | `100`      | Number of bcrypt KDF rounds (`16`..`1000`) used to encrypt the private key when a passphrase is set.                                  |
| `COMMENT`            | file name  | Printable comment stored in the public key (max 256 chars), usually `user@host` or an e-mail address.                                 |
| `REQUIRE_PASSPHRASE` | `no`       | `yes` refuses to generate the key unless a passphrase (min 12 chars) is supplied (`-p` for keys, `-c` for the CA).                    |
| `EXPORT_PEM`         | `no`       | `yes` exports a PKCS#8 PEM private key (`<name>.pem`) and PKCS#8 public key (`<name>.pub.pem`) for `rsa` / `ecdsa` keys.              |
| `EXPORT_PPK`         | `yes`      | `yes` exports a PuTTY `.ppk` private key (PPK v3, Argon2id-encrypted when a passphrase is set).                                       |
| `EXPORT_BASE64`      | `yes`      | `yes` writes single-line `.base64` files for CI/CD secret managers. Set to `no` for personal laptop keys to reduce key copies on disk.|

### Certificate settings (only used when `SIGN_WITH_CA = yes`)

| Setting           | Default              | Description                                                                                                                                                            |
| ----------------- | -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `SIGN_WITH_CA`    | `no`                 | `yes` / `true` signs the public key with the CA and creates `<name>-cert.pub`.                                                                                        |
| `CERT_TYPE`       | `user`               | `user` – certificate for logging in to servers. `host` – certificate that proves a server's identity to clients (must not be encrypted with a key passphrase).        |
| `CERT_IDENTITY`   | file name            | Key ID written into the certificate and shown in `sshd` logs (max 256 printable chars).                                                                               |
| `CERT_PRINCIPALS` | *(required)*         | Comma-separated list of allowed usernames (user cert) or hostnames/IPs (host cert). **Required when `SIGN_WITH_CA = yes`** so wildcard-principal certs cannot be created accidentally. |
| `CERT_VALIDITY`   | `+12w` / `+52w`      | Validity window in `ssh-keygen -V` format (defaults to `+12w` for `user`, `+52w` for `host`). Non-expiring values (`forever` / `always`) are rejected.                |
| `CERT_OPTIONS`    | *(none)*             | Space-separated allowlisted `ssh-keygen -O` options (e.g. `no-x11-forwarding no-agent-forwarding no-port-forwarding no-pty verify-required source-address=10.0.0.0/8`). User certs only. |
| `CERT_SERIAL`     | random 56-bit number | Numeric serial number used for certificate revocation (KRL). Generated randomly from `/dev/urandom` if omitted.                                                        |

## Runtime options (CLI flags & environment variables)

| Flag / Variable      | Default | Description                                                                                             |
| -------------------- | ------- | ------------------------------------------------------------------------------------------------------- |
| `-p` / `KEY_PASSPHRASE` | empty | Key passphrase (min 12 chars when set). Prefer `-p` / `-PromptPassphrase` so it is never stored in shell history or env. |
| `-c` / `CA_PASSPHRASE`  | empty | CA key passphrase (min 12 chars when set), used when creating the CA or signing a certificate.          |
| `REQUEST_NEW_CA_KEY` | `false` | `true` creates a new CA key from `ca.conf` before generating the key.                                   |
| `OVERWRITE`          | `false` | `true` replaces an existing `workspace/keys/<name>/` folder.                                            |
| `OVERWRITE_CA`       | `false` | `true` allows `REQUEST_NEW_CA_KEY=true` to replace an existing CA key in `workspace/ca/ca`.             |

## Minimal example

``` ini
# workspace/conf/github-actions.conf
KEY_TYPE = ed25519
COMMENT  = "github-actions@example.com"
```

``` bash
./new-key.sh github-actions
```
