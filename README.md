# Optimode SFTP

[![Release](https://img.shields.io/github/v/release/optimode/sftp?sort=semver)](https://github.com/optimode/sftp/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Image: ghcr.io](https://img.shields.io/badge/image-ghcr.io%2Foptimode%2Fsftp-blue)](https://github.com/optimode/sftp/pkgs/container/sftp)
[![Image: Docker Hub](https://img.shields.io/badge/image-optimode%2Fsftp-blue)](https://hub.docker.com/r/optimode/sftp)

A minimal (Alpine-based) Docker image that runs **only** an OpenSSH
`internal-sftp` subsystem. Every user is placed in their own **chroot**, cannot
spawn a shell, and has no other access — giving you strong isolation.

Configuration is driven entirely by **environment variables and config files**:
home directory, UID, GID, SSH public key, password, port, and more.

---

## Features

- **Per-user chroot isolation** (`ChrootDirectory` + `internal-sftp`).
- **No shell / no forwarding** — enforced by `ForceCommand internal-sftp`,
  `AllowTcpForwarding no`, `AllowAgentForwarding no`, `PermitTunnel no`.
- **Flexible configuration**: `SFTP_USER`, `SFTP_UID`, `SFTP_GID`, `SFTP_HOME`.
- **Key and/or password** authentication (`SSH_PUBLIC_KEY` / `SFTP_PASSWORD`).
- **Multiuser** driven by config files (`users.conf` + key/password files).
- **Persistent host keys** (stable fingerprint across restarts).
- **Persistent, timestamped logging** (rsyslog): daily files with RFC3339
  timestamps, automatic compression and retention; `docker logs` still works.
- **Healthcheck** that verifies sshd is listening on the port.
- The `sshd_config` is generated at startup and **validated** (`sshd -t`); the
  container refuses to start on an invalid configuration.

---

## Images

| Registry | Image |
| --- | --- |
| GHCR | `ghcr.io/optimode/sftp` |
| Docker Hub | `optimode/sftp` |

Tags follow SemVer: `1.0.0` (immutable, recommended), `1.0`, `1`, and `latest`.

---

## Quick start

### Production (multiuser, published image)

```bash
# 1) Deployment settings
cp .env.example .env
#    edit at least: TZ, SFTP_HOST_PORT

# 2) User configuration
cp etc-sftp/users.conf.example etc-sftp/users.conf
#    define users, e.g.:  alice 1001 1001 /sftp/alice/data
mkdir -p etc-sftp/authorized_keys etc-sftp/passwords
#    put public keys into  etc-sftp/authorized_keys/<name>
#    and/or passwords into etc-sftp/passwords/<name>

# 3) Start
docker compose up -d
```

Connect (default host port `2222`):

```bash
sftp -P 2222 -i ~/.ssh/id_ed25519 alice@localhost
# or interactively:
sftp -P 2222 alice@localhost
```

> `-P` (capital P) is the port flag for `sftp`/`scp`. For `ssh` it is `-p`.

### Development (local build, single primary user)

```bash
cp .env.dev.example .env
docker compose -f docker-compose.dev.yml up -d --build
```

---

## Environment variables

### Runtime (both setups)

| Variable | Default | Description |
| --- | --- | --- |
| `SFTP_USER` | `sftpuser` | Primary user name. **Set to empty (`""`) to disable** the built-in primary user (multiuser/config-file mode). |
| `SFTP_UID` | `1000` | UID for the primary user / default UID for `users.conf` entries |
| `SFTP_GID` | `1000` | GID for the primary user / default GID for `users.conf` entries |
| `SFTP_HOME` | `/sftp/<user>/data` | Home directory the user logs into and can write to |
| `SFTP_CHROOT_BASE` | `/sftp` | Base directory for chroots (extra users: `<base>/<user>/...`) |
| `SSH_PUBLIC_KEY` | *(empty)* | A public key (`ssh-ed25519 AAAA...`) for the primary user |
| `SSH_AUTHORIZED_KEYS_FILE` | *(empty)* | Path to a file with the primary user's key(s) |
| `SFTP_PASSWORD` | *(empty)* | Password for the primary user (if empty with a key → password login disabled) |
| `SFTP_PORT` | `22` | SSH port inside the container |
| `SFTP_HOST_PORT` | `2222` | Host port (compose only) |
| `SFTP_LISTEN` | `0.0.0.0` | Listening interface |
| `SFTP_LOG_LEVEL` | `INFO` | `QUIET`/`ERROR`/`INFO`/`VERBOSE`/`DEBUG` |
| `SFTP_LOG_DIR` | `/var/log/sftp` | Persistent log directory (inside the container) |
| `SFTP_LOG_RETENTION_DAYS` | `14` | Daily log retention in days (`0` = never delete) |
| `SFTP_UMASK` | `0022` | umask applied to files created via SFTP |
| `TZ` | `Europe/Budapest` | Timezone for log timestamps (`tzdata` is installed) |

### Compose-only (healthcheck tuning)

| Variable | Default | Description |
| --- | --- | --- |
| `SFTP_IMAGE_TAG` | `latest` | Published image tag (production compose) |
| `SFTP_HC_INTERVAL` | `30s` | Healthcheck interval |
| `SFTP_HC_TIMEOUT` | `5s` | Healthcheck timeout |
| `SFTP_HC_RETRIES` | `3` | Consecutive failures before `unhealthy` |
| `SFTP_HC_START_PERIOD` | `10s` | Grace period at startup |

### The chroot / home relationship

The chroot root is **always the parent of `SFTP_HOME`** and must be root-owned
and not writable, as OpenSSH requires (this cannot be disabled via `StrictModes`
either — it is a hard sshd requirement). `SFTP_HOME` belongs to the user and is
writable.

```
/sftp/sftpuser/         <- chroot root (root:root, 755)  -> user sees "/"
/sftp/sftpuser/data/    <- SFTP_HOME      (uid:gid, writable) -> user sees "/data"
```

OpenSSH `internal-sftp` starts in the **chroot root**, so the user begins in
`/` (read-only) and the writable area is the `/data` subdirectory. This is the
safe, standard pattern: the chroot root can never be writable, otherwise sshd
refuses the login.

> **Note:** at startup the container sets `SFTP_HOME` to `SFTP_UID:SFTP_GID`
> ownership. With a bind mount the host-side directory ownership changes
> accordingly (an unknown UID shows up as `nobody`). If that is undesirable, use
> a named volume or set `SFTP_UID` to your host user's UID.

---

## Multiuser

Users are declared in `etc-sftp/users.conf`:

```
alice 1001 1001 /sftp/alice/data
bob   1002 1002
```

- uid/gid are optional (default to `SFTP_UID`/`SFTP_GID`).
- home is optional (defaults to `/sftp/<name>/data`).
- Public keys: `etc-sftp/authorized_keys/<name>`
- Passwords: `etc-sftp/passwords/<name>`

The production `docker-compose.yml` already mounts `./etc-sftp` (read-only), so
only a restart is needed after editing:

```bash
docker compose restart
```

---

## Logging

The container runs **rsyslog**, and sshd writes to syslog. Every entry goes to
two places:

1. **Persistent file** on the `sftp-logs` volume: `sshd-YYYYMMDD.log` (daily).
2. **stdout** (`docker logs`), so the usual workflow keeps working.

### Format

RFC3339 timestamp **with year and timezone**, then host, program, PID and message:

```
2026-11-16T10:33:04.464605+01:00 <host> sshd[48]: Accepted publickey for alice from 172.17.0.1 port 47994 ssh2: ED25519 SHA256:...
```

The timezone comes from `TZ` (`tzdata` is installed), e.g. `TZ=Europe/Budapest`
→ `+01:00`/`+02:00` depending on daylight saving.

### Rotation and retention

- **Rotation = daily rollover**: a new `sshd-YYYYMMDD.log` every day.
- On startup, `rotate-logs.sh`:
  - **gzip**-compresses previous days (`sshd-YYYYMMDD.log.gz`),
  - **deletes** anything older than `SFTP_LOG_RETENTION_DAYS` (based on the date
    in the filename, so compression/mtime churn cannot confuse it).
- Today's file is written continuously by rsyslog.

### Access

```bash
docker compose exec sftp tail -f /var/log/sftp/sshd-$(date +%Y%m%d).log
docker logs -f sftp        # stdout mirror
```

### Notes

- If rsyslog fails to start, the entrypoint **falls back** to `sshd -e` (stderr)
  so logs are not lost entirely.
- Files are created with mode `0644` so they are readable from the host.
- For central logging, use a Docker logging driver (syslog/fluentd/journald) on
  the `docker logs` side, or ship the log directory.

---

## Healthcheck

The built-in healthcheck verifies that **sshd is listening on the port**
(from `SFTP_PORT`, default 22):

```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD p="${SFTP_PORT:-22}"; netstat -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${p}$"
```

- Docker runs it **inside the container** periodically (like a `docker exec`),
  with the container environment (so it sees `SFTP_PORT`).
- States: `starting` (during start-period) → `healthy` / `unhealthy`.
- Exit code: `0` = healthy, `1` = unhealthy.

### Overriding / disabling

| Mode | How |
| --- | --- |
| `docker run` partial | `--health-interval=10s --health-retries=5` (the rest is kept) |
| `docker run` disable | `--no-healthcheck` |
| `docker compose` partial | `healthcheck: { test: ["CMD","..."], interval: 10s }` |
| `docker compose` disable | `healthcheck: { disable: true }` |
| In the Dockerfile | `HEALTHCHECK NONE` |

> Compose **merges healthcheck fields** with the image's values: if you only set
> `test`, then `interval`/`timeout`/`retries`/`start_period` come from the image.

> `unhealthy` does **not** restart the container (the `restart` policy does not
> do that). Use an orchestrator (Swarm/K8s) or an `autoheal`-style tool.

### Env-driven tuning (recommended pattern)

Operationally, the **definition** (the `test`) belongs to the image, while the
**policy** (timing, strictness) belongs to the deployment. So keep the `test` in
the Dockerfile and tune only via environment variables in `docker-compose.yml`
(the `test` is then inherited from the image — no duplication):

```yaml
services:
  sftp:
    # ...
    healthcheck:
      # the "test" is intentionally omitted -> inherited from the image
      interval:     "${SFTP_HC_INTERVAL:-30s}"
      timeout:      "${SFTP_HC_TIMEOUT:-5s}"
      retries:      ${SFTP_HC_RETRIES:-3}
      start_period: "${SFTP_HC_START_PERIOD:-10s}"
```

The production compose file already uses this pattern. Typical values:

| Environment | `interval` | `retries` | `start_period` |
| --- | --- | --- | --- |
| Development (fast feedback) | `10s` | `2` | `5s` |
| Production (calm, few alerts) | `60s` | `5` | `30s` |
| Resource-constrained / slow start | `30s` | `3` | `60s` |

---

## Security

- **Always** use `SSH_PUBLIC_KEY` in production; keep password login for testing.
- `PermitRootLogin no` and `PermitEmptyPasswords no` are on by default.
- The chroot root is root-owned and not writable — set automatically, do not
  change it by hand.
- Keep the `sftp-hostkeys` volume persistent so host key fingerprints stay
  stable.
- The container serves SFTP only: no shell and no channel forwarding.

See [SECURITY.md](SECURITY.md) for the full policy.

---

## Platform notes

### Debian 13 (Trixie): "UNIX socket creation denied" by AppArmor

After upgrading the **host** to Debian 13 (Trixie), AppArmor ships a stricter
profile that **denies UNIX socket creation inside containers**. The container's
logging stack needs to create the `/dev/log` socket (rsyslog listens on it and
sshd writes to it), so with the default profile the socket cannot be created and
logging falls back to stderr.

**Symptom** — in `docker logs` you see something like:

```
rsyslogd: omfile: creating ... failed
# or, from the entrypoint:
[sftp-init] WARNING: rsyslog failed to start -- logs will go to stderr (docker logs) only
```

**Fix** — unconfine AppArmor for this container. It is already set in both
provided compose files:

```yaml
services:
  sftp:
    # ...
    security_opt:
      - apparmor=unconfined   # Needed after the Trixie upgrade - UNIX socket creation denied
```

For `docker run`, pass the equivalent flag:

```bash
docker run --security-opt apparmor=unconfined ...
```

**Security note.** `apparmor=unconfined` disables the AppArmor confinement of
this container. The container is already minimal and hardened (no shell, no
forwarding, per-user chroot, non-root host processes not required), so the
practical impact is limited — but it *is* a reduction in defence-in-depth. On
hosts that do **not** exhibit the problem (older Debian/Ubuntu, most other
distros) you can remove the `security_opt` block. If you must keep AppArmor
enabled on Trixie, load a custom profile that allows `unix` socket creation
instead of unconfining the container:

```bash
# example: a local profile named "optimode-sftp" that allows unix sockets
sudo apparmor_parser -r -W /etc/apparmor.d/optimode-sftp
# then in compose: security_opt: [ "apparmor=optimode-sftp" ]
```

---

## Troubleshooting

Logs:

```bash
docker compose logs -f sftp                                   # stdout
docker compose exec sftp tail -f /var/log/sftp/sshd-$(date +%Y%m%d).log
```

Test a connection with verbose logging:

```bash
sftp -vvv -P 2222 alice@localhost
```

If sshd rejects the login due to the chroot
(`bad ownership or modes for chroot directory`), check that the chroot root is
root-owned:

```bash
docker compose exec sftp ls -ld /sftp/alice
```

---

## Publishing (maintainers)

A GitHub Actions workflow (`.github/workflows/release.yml`) builds a
**multi-arch** image (`linux/amd64`, `linux/arm64`) and pushes it to both
registries when a version tag is pushed:

- **GHCR**: `ghcr.io/optimode/sftp`
- **Docker Hub**: `optimode/sftp`

### Tag behaviour

| Tag pushed | Resulting image tags |
| --- | --- |
| `v1.0.0` (stable) | `1.0.0`, `1.0`, `1`, `latest` |
| `v1.0.0-rc1` (pre-release) | `1.0.0-rc1` only |

Pre-release (RC) tags never move `latest`, `1` or `1.0`.

### Cutting a release

```bash
# release candidate (staging/testing)
git tag -a v1.0.0-rc1 -m "Release Candidate 1.0.0-rc1"
git push origin v1.0.0-rc1

# stable release (after the RC has been validated)
git tag -a v1.0.0 -m "Release v1.0.0"
git push origin v1.0.0
```

### Required secrets

The workflow needs two repository secrets (Settings → Secrets and variables →
Actions), both already used by the Docker Hub login step:

- `DOCKERHUB_USERNAME` = `optimode`
- `DOCKERHUB_TOKEN` = a Docker Hub **access token** (Account Settings →
  Security → *New Access Token*, read/write) — never the account password.

The `optimode` Docker Hub namespace must exist and the token must have push
rights to the `sftp` repository.

> For GHCR, make the package **public** after the first push
> (Package settings → Change visibility) if you want anonymous pulls.

---

## Maintenance

The image is kept fresh by automation; the policy is:

| Change | Release |
| --- | --- |
| Base image / package security patch (same Alpine branch) | **PATCH** (`1.0.1`) |
| New feature / option | **MINOR** (`1.1.0`) |
| Breaking change (e.g. Alpine major with changed behaviour) | **MINOR/MAJOR** |

### Automation

- **Dependabot** (`.github/dependabot.yml`) — weekly PRs for a newer `FROM alpine:<tag>`
  in the Dockerfile and for newer GitHub Actions versions.
- **CI** (`.github/workflows/ci.yml`) — on every push to `main` and on every PR it
  builds the image, runs a smoke test (sshd listens) and a **Trivy** vulnerability
  scan (`CRITICAL,HIGH`, `exit-code: 1`). Good candidate for a required status
  check in branch protection.
- **Scheduled rebuild** (`.github/workflows/rebuild.yml`) — on the 1st of every
  month it does a **no-cache** multi-arch build, pushes it to the `:edge` tag, and
  opens an issue if `:edge` differs from `:latest` (i.e. Alpine shipped updates),
  so a patch release can be cut.
- **Vulnerability alerts** are enabled on the repository (Dependabot alerts and
  automated security updates).

> Why `--no-cache` matters: the `RUN apk add` layer is cached, so a normal
> rebuild does **not** pick up new package revisions within the same Alpine tag.
> Only a no-cache build (or a base-tag change) refreshes them.

### Checking for updates manually

```bash
# newest Alpine branch available
docker run --rm alpine:latest cat /etc/alpine-release

# OpenSSH in the pinned branch vs the newest branch
docker run --rm alpine:3.24 sh -c 'apk add --no-cache --simulate openssh-server 2>&1 | grep Installing'
docker run --rm alpine:latest sh -c 'apk add --no-cache --simulate openssh-server 2>&1 | grep Installing'

# what our published image currently ships
docker run --rm --entrypoint sh optimode/sftp:latest -c 'cat /etc/alpine-release; apk info -v | grep openssh-server'
```

Useful watches: [Alpine releases](https://alpinelinux.org/releases/),
[Alpine security advisories](https://security.alpinelinux.org/),
[OpenSSH release notes](https://www.openssh.com/releasenotes.html).

---

## Files

| File | Description |
| --- | --- |
| `Dockerfile` | Image definition (Alpine + OpenSSH + rsyslog + tini) |
| `entrypoint.sh` | User/chroot/`sshd_config` generation + logging startup |
| `rsyslog.conf` | Timestamped logging (daily file + stdout) |
| `rotate-logs.sh` | Daily log gzip compression + retention cleanup |
| `docker-compose.yml` | Production compose (published image, multiuser) |
| `docker-compose.dev.yml` | Development compose (local build, single user) |
| `.env.example` | Production environment template |
| `.env.dev.example` | Development environment template |
| `etc-sftp/users.conf.example` | Multiuser configuration template |
| `.github/workflows/release.yml` | CI: tag → multi-arch build & push (GHCR + Docker Hub) |
| `.github/workflows/ci.yml` | CI: build + smoke test + Trivy scan (push/PR) |
| `.github/workflows/rebuild.yml` | Monthly no-cache rebuild → `:edge` + issue on change |
| `.github/dependabot.yml` | Weekly dependency updates (base image + Actions) |
| `CHANGELOG.md` | Release history |
| `SECURITY.md` | Security policy |

---

## License

[MIT](LICENSE) © Optimode
