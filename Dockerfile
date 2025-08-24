# Debian-based because your script is written for /bin/bash
FROM debian:stable-slim

# Install bash (already present, but we keep it explicit) and netcat
RUN apt-get update
RUN apt-get install -y --no-install-recommends \
        bash \
        curl \
        coreutils \
        jq \
        netcat-traditional \
        sed
RUN rm -rf /var/lib/apt/lists/*