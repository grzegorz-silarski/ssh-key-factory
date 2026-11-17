# Introduction

SSH Key Factory is an initiative that introduces a common standard for creating valid and secure SSH keys and SSH certificates. This solution is a Docker-based tool that enables anyone to easily create a set of SSH keys and related files, without depending on the OpenSSH version installed locally.
In details it creates:

- private key in OpenSSH format (`0600`)
- public key in OpenSSH (`authorized_keys`) format (`0644`)
- public key in RFC4716 (SSH2) format
- optional private key in PKCS#8 PEM format and public key in PKCS#8 format (`EXPORT_PEM = yes`, RSA and ECDSA only)
- optional private key in PuTTY (`.ppk`) format (`EXPORT_PPK = yes`, default)
- optionally, a user or host SSH certificate signed by your SSH CA (`<name>-cert.pub`)
- SHA256 fingerprint and randomart
- optional single-line base64 representation of the above (`EXPORT_BASE64 = yes`, default) – handy for CI/CD secrets

This initiative assumes that OpenSSH (`ssh-keygen`) and PuTTY (`puttygen`) industry standard tools are leveraged here.

## Getting Started

All you need to do is to build the docker image that is the heart of this solution. Just execute commands below to do so:

Bash:

``` bash
./build.sh
```

PowerShell Core:

``` powershell
pwsh ./Build.ps1
```

To create a new key just use, or modify to fit your needs, one of the configuration files placed in the `workspace/conf` folder (`example.conf`, `legacy-rsa.conf`, `user-cert.conf`, `host-cert.conf`). Those files are simple `KEY = VALUE` files; lines starting with `#` are comments. See [workspace/conf/README.md](workspace/conf/README.md) for a description of each example file, which one to pick for SSH terminal sessions, and every setting.

| Setting              | Default         | Description                                                                          |
| -------------------- | --------------- | ------------------------------------------------------------------------------------ |
| `KEY_TYPE`           | `ed25519`       | `ed25519` (recommended), `ecdsa` or `rsa`                                            |
| `KEY_BITS`           | -               | RSA: `3072`..`16384` (default `4096`); ECDSA: `256`, `384` (default) or `521`        |
| `KDF_ROUNDS`         | `100`           | bcrypt KDF rounds (`16`..`1000`) protecting the private key when a passphrase is set |
| `COMMENT`            | name            | Key comment (max 256 printable chars)                                                |
| `REQUIRE_PASSPHRASE` | `no`            | `yes` requires a passphrase (min 12 chars) when generating the key                   |
| `EXPORT_PEM`         | `no`            | `yes` exports PKCS#8 `.pem` and `.pub.pem` files (RSA/ECDSA only)                    |
| `EXPORT_PPK`         | `yes`           | `yes` exports a PuTTY `.ppk` file                                                    |
| `EXPORT_BASE64`      | `yes`           | `yes` writes single-line `.base64` files for CI/CD secrets                           |
| `SIGN_WITH_CA`       | `no`            | `yes` creates an SSH certificate signed by the CA in `workspace/ca`                  |
| `CERT_TYPE`          | `user`          | `user` or `host`                                                                     |
| `CERT_IDENTITY`      | name            | Certificate key identity (shown in `sshd` logs)                                      |
| `CERT_PRINCIPALS`    | *(required)*    | Comma-separated usernames (user cert) or hostnames/IPs (host cert)                   |
| `CERT_VALIDITY`      | `+12w` / `+52w` | Validity interval in `ssh-keygen -V` format (`forever`/`always` disallowed)          |
| `CERT_OPTIONS`       | -               | Space-separated allowlisted `ssh-keygen -O` options, e.g. `no-x11-forwarding`        |
| `CERT_SERIAL`        | random 56-bit   | Numeric certificate serial (random by default for KRL revocation)                    |

If your configuration is done just run following commands:

Bash:

``` bash
./new-key.sh [-p] [-c] <configuration_name>
```

PowerShell Core:

``` powershell
pwsh ./New-Key.ps1 [-PromptPassphrase] [-PromptCaPassphrase] <configuration_name>
```

`configuration_name` is the name of the configuration file (without `.conf`) you'd like to use to create your key. All files are written to `workspace/keys/<configuration_name>/`.

### Runtime options

| Flag / Variable      | Default | Description                                                                                             |
| -------------------- | ------- | ------------------------------------------------------------------------------------------------------- |
| `-p` / `KEY_PASSPHRASE` | empty | Passphrase protecting the private key (min 12 chars). Prefer `-p` / `-PromptPassphrase` interactively. |
| `-c` / `CA_PASSPHRASE`  | empty | Passphrase for the SSH CA key (min 12 chars). Prefer `-c` / `-PromptCaPassphrase` interactively.       |
| `REQUEST_NEW_CA_KEY` | `false` | `true` creates a new SSH CA key in `workspace/ca` (using `conf/ca.conf`) first                          |
| `OVERWRITE`          | `false` | `true` replaces an already existing key in `workspace/keys/<name>`                                      |
| `OVERWRITE_CA`       | `false` | `true` allows replacing an existing CA key when `REQUEST_NEW_CA_KEY=true`                               |

Examples:

``` bash
# Interactive key with passphrase prompt
./new-key.sh -p example

# Create a new encrypted SSH CA and a user certificate signed by it
REQUEST_NEW_CA_KEY=true ./new-key.sh -p -c user-cert

# Sign a server host certificate using the existing encrypted CA
./new-key.sh -c host-cert
```

## Security Design

- **Zero secret leakage in process table or container metadata:** Passphrases are piped to the container over `STDIN` and fed to `ssh-keygen` via `SSH_ASKPASS` backed by an in-memory `tmpfs` file (`0600`), never via `-N`/`-P` CLI arguments (`ps`) or container `-e` variables (`docker inspect`).
- **Least-privilege container execution:** Runs as the host's non-root `UID:GID` with `--network none`, `--read-only` rootfs, `--cap-drop ALL`, `--security-opt no-new-privileges`, and `workspace/conf` mounted read-only.
- **Safe config parser:** `workspace/conf/*.conf` files are parsed line-by-line with globbing disabled (`set -f`) and strict allowlists—never sourced as shell scripts.
- **Safe certificate defaults:** `CERT_PRINCIPALS` is mandatory when signing, infinite validity (`forever`/`always`) is rejected, each certificate gets a random 56-bit serial for KRL revocation, and the CA private key is encrypted and overwrite-protected by default.

## Contribute

Despite that the DevOps team is a creator and owner of this source code we are very happy to welcome everyone to participate to this project in an inner source model.

Our inner source model assumes that everyone can create a feature branch of the main branch and contribute source code in a pull request fashion.

We accept feature branches of the following naming convention pattern: `feature/<your-branch-name>`
Please use lowercase letters and dashes as a word separators. Thank you!

## FAQ

Q: I have an existing SSH CA key, can I use it rather than creating a new one?
A: Yes, you can use any SSH CA key to sign the keys you'd like to create. Just follow steps on this page [How to use my own SSH CA key](workspace/ca/README.md)

Q: Why is there no PEM file for Ed25519 keys?
A: Ed25519 private keys can only be stored in the OpenSSH format by `ssh-keygen`. Use the OpenSSH or `.ppk` files instead.
