#!/bin/sh
# ===========================================================================
#  rotate-logs.sh -- compress daily log files and enforce retention
#
#  rsyslog writes daily files (sshd-YYYYMMDD.log), so "rotation" is simply the
#  daily rollover. On startup (and optionally on demand) this script:
#    1. deletes files older than the retention window (based on the date in the
#       filename -- so gzip/mtime churn cannot confuse it)
#    2. gzip-compresses the files of previous days (never today's file)
#
#  Environment variables:
#    SFTP_LOG_DIR             (default: /var/log/sftp)
#    SFTP_LOG_RETENTION_DAYS  (default: 14, 0 = never delete)
# ===========================================================================
set -eu

LOG_DIR="${SFTP_LOG_DIR:-/var/log/sftp}"
RETENTION="${SFTP_LOG_RETENTION_DAYS:-14}"
TODAY="$(date +%Y%m%d)"

mkdir -p "$LOG_DIR"

# Cutoff date (YYYYMMDD) via epoch arithmetic. BusyBox `date -d '-N days'` is
# not supported, but `date -d @epoch` is.
CUTOFF=""
if [ "$RETENTION" -gt 0 ] 2>/dev/null; then
    CUTOFF="$(date -d "@$(( $(date +%s) - RETENTION * 86400 ))" +%Y%m%d)"
fi

# --- 1) retention: delete by the date encoded in the filename ---
for f in "$LOG_DIR"/sshd-*.log "$LOG_DIR"/sshd-*.log.gz; do
    [ -e "$f" ] || continue
    base="${f##*/}"          # sshd-YYYYMMDD.log[.gz]
    d="${base#sshd-}"        # YYYYMMDD.log[.gz]
    d="${d%.gz}"             # YYYYMMDD.log
    d="${d%.log}"            # YYYYMMDD
    case "$d" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;  # valid date format only
        *) continue ;;
    esac
    if [ -n "$CUTOFF" ] && [ "$d" -lt "$CUTOFF" ]; then
        rm -f "$f"
    fi
done

# --- 2) compress previous days (leave today's file alone) ---
for f in "$LOG_DIR"/sshd-*.log; do
    [ -e "$f" ] || continue
    base="${f##*/}"
    d="${base#sshd-}"
    d="${d%.log}"
    if [ "$d" != "$TODAY" ] && [ ! -f "${f}.gz" ]; then
        gzip -9 "$f" 2>/dev/null || true
    fi
done

exit 0
