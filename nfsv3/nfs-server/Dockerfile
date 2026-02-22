FROM ubuntu:18.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       nfs-kernel-server \
       rpcbind \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd -g 1500 ccexportuser \
    && useradd -m -u 1500 -g 1500 -s /bin/bash ccexportuser

RUN mkdir -p /exports/share

COPY entrypoint.sh /entrypoint.sh
COPY check_exports_consistency.sh /usr/local/bin/check_exports_consistency.sh
RUN chmod +x /entrypoint.sh
RUN chmod +x /usr/local/bin/check_exports_consistency.sh

EXPOSE 111/tcp 111/udp 2049/tcp 2049/udp

ENTRYPOINT ["/entrypoint.sh"]
