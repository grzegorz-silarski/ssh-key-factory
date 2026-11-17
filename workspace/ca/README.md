# How to work with the SSH CA key

Place your `ca` (private) and `ca.pub` (public) SSH CA key files into this folder if you intend to use an existing SSH Certificate Authority rather than creating a new one.

To create a new `ca` and `ca.pub` automatically (using settings from `workspace/conf/ca.conf`), set `REQUEST_NEW_CA_KEY=true` and pass `-c` (Bash) or `-PromptCaPassphrase` (PowerShell) to prompt for the CA passphrase:

``` bash
REQUEST_NEW_CA_KEY=true ./new-key.sh -p -c user-cert
```

> [!CAUTION]
> An existing CA key in `workspace/ca/ca` is protected against accidental replacement. Even when `REQUEST_NEW_CA_KEY=true` is set, the tool will refuse to overwrite an existing CA unless you also set `OVERWRITE_CA=true` (replacing a CA invalidates every certificate previously signed by it).

> [!IMPORTANT]
> By default, `workspace/conf/ca.conf` sets `REQUIRE_PASSPHRASE = yes` so the CA private key is encrypted at rest (minimum 12 characters). Never commit `workspace/ca/ca` to version control.

## Trusting the CA

- **User certificates** – on every server, copy `ca.pub` to e.g. `/etc/ssh/trusted_user_ca.pub` and add to `sshd_config`:

  ```text
  TrustedUserCAKeys /etc/ssh/trusted_user_ca.pub
  ```

- **Host certificates** – on clients, add to `~/.ssh/known_hosts`:

  ```text
  @cert-authority *.example.com <contents of ca.pub>
  ```

  and on the server add to `sshd_config`:

  ```text
  HostKey /etc/ssh/<name>
  HostCertificate /etc/ssh/<name>-cert.pub
  ```

## Revoking a user certificate (KRL)

Every signed certificate receives a unique 56-bit serial number (shown in `<name>-cert.txt` and `sshd` logs) unless overridden via `CERT_SERIAL`. To revoke a certificate before it expires:

``` bash
ssh-keygen -k -f /etc/ssh/revoked_keys -s /etc/ssh/trusted_user_ca.pub -z <serial>
```

and configure `RevokedKeys /etc/ssh/revoked_keys` in `sshd_config`.
