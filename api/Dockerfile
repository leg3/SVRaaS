FROM rocker/r-ver:4.6.1

ENV SVRAAS_ARTIFACT_ROOT=/artifacts

WORKDIR /opt/svraas/api

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libsodium23 \
        libwebpmux3 \
        libuv1t64 \
    && rm -rf /var/lib/apt/lists/*

RUN install2.r --error --skipinstalled plumber2 jsonlite

COPY plumber.R /opt/svraas/api/plumber.R
COPY R /opt/svraas/api/R

EXPOSE 8000

CMD ["Rscript", "-e", "parsed_api <- plumber2::api('plumber.R', doc_type = NULL); plumber2::api_run(parsed_api, host = '0.0.0.0', port = 8000, block = TRUE, showcase = FALSE, silent = FALSE)"]

