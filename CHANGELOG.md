# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-11-16

First public release. Published as the `optimode/sftp` image.

### Added

- Minimal Alpine-based image that runs **only** an OpenSSH `internal-sftp`
  subsystem; no shell and no other services.
- **Per-user chroot isolation** (`ChrootDirectory` + `ForceCommand internal-sftp`),
  with hardening: `X11Forwarding no`, `AllowTcpForwarding no`,
  `AllowAgentForwarding no`, `PermitTunnel no`, `GatewayPorts no`.
- **Environment-driven configuration**: `SFTP_USER`, `SFTP_UID`, `SFTP_GID`,
  `SFTP_HOME`, `SFTP_CHROOT_BASE`, `SFTP_PORT`, `SFTP_LISTEN`, `SFTP_LOG_LEVEL`,
  `SFTP_UMASK`, `TZ`.
- **Key and/or password authentication** via `SSH_PUBLIC_KEY`,
  `SSH_AUTHORIZED_KEYS_FILE` and `SFTP_PASSWORD`.
- **Multiuser support** driven by config files: `etc-sftp/users.conf`,
  `etc-sftp/authorized_keys/<name>` and `etc-sftp/passwords/<name>`. Setting
  `SFTP_USER` to empty disables the built-in primary user for pure
  config-file deployments.
- **Persistent, timestamped logging** via rsyslog: daily files
  (`/var/log/sftp/sshd-YYYYMMDD.log`) with RFC3339 timestamps (year + timezone),
  automatic gzip compression of previous days, and a configurable retention
  window (`SFTP_LOG_RETENTION_DAYS`). Messages are also mirrored to stdout so
  `docker logs` keeps working.
- **Container healthcheck** that verifies sshd is listening on the port.
- **Generated and validated `sshd_config`**: built at startup and checked with
  `sshd -t`; the container refuses to start on an invalid configuration.
- **Developer and production compose files**: `docker-compose.dev.yml`
  (local build, single primary user) and `docker-compose.yml` (published image,
  multiuser from config files).
- **GitHub Actions CI** that builds and pushes a multi-arch image to GHCR on
  version tags.

### Fixed

- Public-key logins were rejected with "account is locked" because `adduser`
  creates a locked account; accounts are now unlocked (with a random password
  when no password is provided).
- The healthcheck reported a false `unhealthy` state (`pgrep -x sshd` does not
  match OpenSSH's rewritten process title); it now checks the listening port.
- Log retention did not delete old files because gzip resets the file mtime;
  retention now relies on the date encoded in the filename.
- Multiuser parsing overwrote the container command (`set --` clobbering `$@`);
  switch to a `read`-based parser.
- `rsyslog`'s `omstdout` module is now loaded explicitly so stdout mirroring
  works.

### Security

- No shell, no port/agent forwarding, no tunnelling, no root login, empty
  passwords disabled, and strict file-ownership checks on chroots.

[Unreleased]: https://github.com/optimode/sftp/compare/1.0.0...HEAD
[1.0.0]: https://github.com/optimode/sftp/releases/tag/1.0.0
