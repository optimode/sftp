# Security Policy

## Reporting a Vulnerability

Please report security issues through the project's GitHub Issues page:

- https://github.com/optimode/sftp/issues

When opening an issue, please include:

- a description of the issue and its impact,
- steps to reproduce (a proof of concept if possible),
- the affected version/tag and your environment.

We aim to acknowledge reports within a few business days and to provide a
remediation timeline after triage.

## Supported Versions

Only the latest published release receives security fixes.

| Version | Supported |
| ------- | --------- |
| latest  | yes       |
| older   | no        |

## Security Design

This image is intentionally minimal and locked down:

- **Per-user chroot** via `ChrootDirectory` + `ForceCommand internal-sftp`:
  users are confined to their own directory tree.
- **No shell**: the SFTP subsystem never spawns a login shell; users get a
  `/sbin/nologin` shell.
- **No forwarding**: `AllowTcpForwarding no`, `AllowAgentForwarding no`,
  `X11Forwarding no`, `PermitTunnel no`, `GatewayPorts no`.
- **No root login**: `PermitRootLogin no`, `PermitEmptyPasswords no`.
- The generated `sshd_config` is validated with `sshd -t` at startup, and the
  container refuses to start on an invalid configuration.

## Operational Hardening

- Prefer **public keys** over passwords. Passwords are intended for testing;
  disable them in production.
- Mount the user configuration (`./etc-sftp`) **read-only**.
- Keep the `sftp-hostkeys` volume persistent so host key fingerprints stay
  stable (prevents client trust warnings from being blindly accepted).
- Run the container as a non-root host user is not required (sshd needs to
  manage accounts and chroots), but restrict host access to the container
  engine and its volumes.
- Review logs under `/var/log/sftp` (or the `sftp-logs` volume).

## Known Limitations

- **Legacy SCP protocol is not supported** (and cannot be, without weakening
  the chroot). Modern `scp` (OpenSSH >= 9.0) uses the SFTP protocol and works;
  `scp -O` and the WinSCP "SCP" protocol do not.
- Uploaded content is not scanned; antivirus/quota enforcement is out of scope.
