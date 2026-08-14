FROM debian:13.6-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        nfs-ganesha=6.5-5 \
        nfs-ganesha-vfs=6.5-5 \
    && rm -rf /var/lib/apt/lists/*

COPY ganesha.conf /etc/ganesha/ganesha.conf

RUN mkdir -p /export/artifacts /var/run/ganesha

EXPOSE 2049/tcp

COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

CMD ["ganesha.nfsd", "-F", "-L", "STDERR", "-f", "/etc/ganesha/ganesha.conf"]

