FROM ubuntu:18.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       nfs-common \
       netbase \
       netcat-openbsd \
       python3-pip \
       python3 \
    && pip3 install --no-cache-dir dataclasses \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd -g 1234 maglev \
    && useradd -m -u 1234 -g 1234 -s /bin/bash maglev \
    && groupadd -g 1001 postgres \
    && useradd -m -u 1001 -g 1001 -s /bin/bash postgres \
    && groupadd -g 1002 mongodb \
    && useradd -m -u 1002 -g 1002 -s /bin/bash mongodb \
    && groupadd -g 1003 elasticsearch \
    && useradd -m -u 1003 -g 1003 -s /bin/bash elasticsearch

RUN mkdir -p /mnt/nfs

COPY entrypoint.sh /entrypoint.sh
COPY validate_readme_matrix.py /usr/local/bin/validate_readme_matrix.py
COPY catalystcenter_compatibility_check.py /usr/local/bin/catalystcenter_compatibility_check.py
RUN chmod +x /entrypoint.sh
RUN chmod +x /usr/local/bin/validate_readme_matrix.py
RUN chmod +x /usr/local/bin/catalystcenter_compatibility_check.py

ENTRYPOINT ["/entrypoint.sh"]
