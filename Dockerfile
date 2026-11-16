# ---------------------------------------------------------------------------
# Optimode SFTP -- OpenSSH-based SFTP server with per-user chroot isolation
# ---------------------------------------------------------------------------
FROM alpine:3.24

ARG SFTP_VERSION=dev
ARG GIT_REVISION=

LABEL org.opencontainers.image.title="Optimode SFTP" \
      org.opencontainers.image.description="OpenSSH-based SFTP server with per-user chroot isolation" \
      org.opencontainers.image.source="https://github.com/optimode/sftp" \
      org.opencontainers.image.url="https://github.com/optimode/sftp" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${SFTP_VERSION}" \
      org.opencontainers.image.revision="${GIT_REVISION}"

# openssh-server : sshd + internal-sftp
# bash           : required by the entrypoint
# tini           : proper PID1 signal/reaping
# rsyslog        : timestamped persistent logging (file + stdout)
# tzdata         : makes the TZ environment variable work correctly
RUN apk add --no-cache \
        openssh-server \
        openssh-client-default \
        bash \
        tini \
        rsyslog \
        tzdata \
    && rm -rf /var/cache/apk/*

# Runtime directories
RUN mkdir -p /run/sshd /etc/sftp /etc/sftp/authorized_keys /etc/sftp/passwords \
             /sftp /var/log/sftp /var/spool/rsyslog

COPY rsyslog.conf     /etc/rsyslog.conf
COPY rotate-logs.sh   /usr/local/bin/rotate-logs.sh
COPY entrypoint.sh    /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/rotate-logs.sh

EXPOSE 22

# /etc/ssh      -> persist host keys
# /sftp         -> chroot base directory (data volume)
# /var/log/sftp -> persistent, timestamped logs (daily files)
VOLUME ["/etc/ssh", "/sftp", "/var/log/sftp"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD p="${SFTP_PORT:-22}"; netstat -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${p}$"

# -g: forward signals to the whole process group (so rsyslog shuts down
#     cleanly alongside sshd)
ENTRYPOINT ["/sbin/tini", "-g", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["/usr/sbin/sshd", "-D"]
