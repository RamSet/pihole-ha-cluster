# pihole-ha sidecar — runs alongside stock pihole/pihole container
# Build context is repo root: docker build -f docker/Dockerfile -t pihole-ha .

# Stage 1: grab pihole-FTL binary for --config CLI
FROM pihole/pihole:latest AS pihole-src

# Stage 2: Alpine sidecar
FROM alpine:3.21

RUN apk add --no-cache \
    bash \
    curl \
    socat \
    openssl \
    iproute2 \
    arping \
    netcat-openbsd \
    procps \
    coreutils \
    grep \
    sed \
    tar \
    gzip

# Copy pihole-FTL binary (needed for --config CLI to signal running FTL)
COPY --from=pihole-src /usr/bin/pihole-FTL /usr/bin/pihole-FTL

# Install platform abstraction + management CLI
COPY pihole-ha-platform /usr/local/lib/pihole-ha/pihole-ha-platform
COPY pihole-ha-cli /usr/local/lib/pihole-ha/pihole-ha-cli

# Install pihole-ha scripts
COPY pihole-ha /usr/local/bin/pihole-ha
COPY pihole-ha-dash /usr/local/bin/pihole-ha-dash
COPY pihole-ha-sync /usr/local/bin/pihole-ha-sync
COPY pihole-ha-sync-pull /usr/local/bin/pihole-ha-sync-pull
COPY new-dhcp-device /usr/local/bin/new-dhcp-device
COPY pihole-ha-oui-update /usr/local/bin/pihole-ha-oui-update
RUN chmod 755 /usr/local/bin/pihole-ha* /usr/local/bin/new-dhcp-device /usr/local/lib/pihole-ha/pihole-ha-platform /usr/local/lib/pihole-ha/pihole-ha-cli


# Install Pi-hole admin panel integration source files
COPY ha.lp /usr/local/share/pihole-ha/ha.lp
COPY ha-api.lp /usr/local/share/pihole-ha/ha-api.lp
COPY ha.js /usr/local/share/pihole-ha/ha.js

# Install entrypoint and inject script
COPY docker/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY docker/pihole-ha-inject-docker.sh /usr/local/bin/pihole-ha-inject-docker.sh
RUN chmod 755 /usr/local/bin/docker-entrypoint.sh /usr/local/bin/pihole-ha-inject-docker.sh

# Create runtime directories
RUN mkdir -p /run/pihole-ha /etc/pihole-ha /var/lib/ieee-data

# Docker marker for platform detection
RUN touch /.dockerenv

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
