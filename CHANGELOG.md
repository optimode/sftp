# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-11-16

First stable release. Validated on staging as `v1.0.0-rc1`; the stable release
additionally includes the Alpine 3.24 base bump, the AppArmor compose fix and
the maintenance automation, which landed after the candidate.

### Added

- Minimal Alpine-based image that runs **only** an OpenSSH `internal-sftp`
  subsystem; no shell and no other services.
- **Per-user chroot isolation** (`ChrootDirectory` + `ForceCommand internal-sftp`),
  with hardening: `X11Forwarding no`, `AllowTcpForwarding no`,
  `AllowAgentForwarding no`, `PermitTunnel no`, `GatewayPorts no`.
- **Environment-driven configuration**: `SFTP_USER`, `SFTP_UID`, `SFTP_GID`,
  `SFTP_HOME`, `SFTP_CHROOT_BASE`, `SFTP_PORT`, `SFTP_LISTEN`, `SFTP_LOG_LEVEL`,
  `SFTP_LOG_DIR`, `SFTP_LOG_RETENTION_DAYS`, `SFTP_UMASK`, `TZ`.
- **Key and/or password authentication** via `SSH_PUBLIC_KEY`,
  `SSH_AUTHORIZED_KEYS_FILE` and `SFTP_PASSWORD`.
- **Multiuser support** driven by config files: `etc-sftp/users.conf`,
  `etc-sftp/authorized_keys/<name>` and `etc-sftp/passwords/<name>`. Setting
  `SFTP_USER` to empty disables the built-in primary user for pure
  config-file deployments; the container fails fast when no user is defined.
- **Persistent, timestamped logging** via rsyslog: daily files
  (`/var/log/sftp/sshd-YYYYMMDD.log`) with RFC3339 timestamps (year + timezone),
  automatic gzip compression of previous days, and a configurable retention
  window. Messages are also mirrored to stdout so `docker logs` keeps working.
- **Container healthcheck** that verifies sshd is listening on the port, with
  environment-driven timing via `docker-compose.yml`.
- **Generated and validated `sshd_config`**: built at startup and checked with
  `sshd -t`; the container refuses to start on an invalid configuration.
- **Developer and production compose files**: `docker-compose.dev.yml`
  (local build, single primary user) and `docker-compose.yml` (published image,
  multiuser from config files).
- **Published multi-arch images** (`linux/amd64`, `linux/arm64`) on GHCR
  (`ghcr.io/optimode/sftp`) and Docker Hub (`optimode/sftp`), built by CI on
  version tags. Pre-release tags do not move the `latest`, `1` or `1.0` tags.

### Changed

- Base image bumped from `alpine:3.20` to **`alpine:3.24`**, bringing
  **OpenSSH `10.3`** (up from `9.7`) and a newer rsyslog. No configuration or
  behaviour changes; the change is transparent to SFTP clients.
- The Docker Hub `security_opt: [apparmor=unconfined]` entry is now present in
  both compose files by default (see Fixed).

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
- The container could not create the rsyslog `/dev/log` UNIX socket on Debian 13
  (Trixie), where a stricter AppArmor profile denies UNIX socket creation inside
  containers; logging then fell back to stderr. Both compose files now set
  `security_opt: [apparmor=unconfined]`, documented under "Platform notes".

### Security

- No shell, no port/agent forwarding, no tunnelling, no root login, empty
  passwords disabled, and strict file-ownership checks on chroots.
- The Alpine 3.24 base removes fixable HIGH-severity findings (`musl`) that were
  present in the 3.20 base.

### Internal improvements

- Added maintenance automation: **Dependabot** (weekly PRs for the base image
  and GitHub Actions), a **CI** workflow (build + smoke test + **Trivy**
  vulnerability scan on push/PR) and a **monthly no-cache rebuild** workflow
  that publishes `:edge` and opens an issue when the base image or packages
  change. Repository vulnerability alerts are enabled.

## [1.0.0-rc1] - 2026-11-16

First release candidate for `1.0.0` (staging/testing artifact, **not**
production-ready at the time). Superseded by `1.0.0`, which adds the Alpine 3.24
base bump, the AppArmor compose fix and the maintenance automation; see the
`1.0.0` section for the complete change set.

[Unreleased]: https://github.com/optimode/sftp/compare/1.0.0...HEAD
[1.0.0]: https://github.com/optimode/sftp/releases/tag/v1.0.0
[1.0.0-rc1]: https://github.com/optimode/sftp/releases/tag/v1.0.0-rc1
