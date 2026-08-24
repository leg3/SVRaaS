FROM rocker/r-ver:4.6.1

ENV VIRTUAL_ENV=/opt/svraas/venv \
    RETICULATE_PYTHON=/opt/svraas/venv/bin/python \
    KERAS_BACKEND=tensorflow \
    SVRAAS_ARTIFACT_ROOT=/artifacts \
    PATH="/opt/svraas/venv/bin:${PATH}"

WORKDIR /opt/svraas

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        libpython3.12t64 \
        python3 \
        python3-venv \
    && rm -rf /var/lib/apt/lists/*

RUN install2.r --error --skipinstalled \
    forecast \
    tidyverse \
    lubridate \
    jsonlite \
    remotes \
    keras3

RUN Rscript -e 'remotes::install_github("leg3/pipewelder", upgrade = "never")'

RUN python3 -m venv "${VIRTUAL_ENV}" \
    && "${VIRTUAL_ENV}/bin/python" -m pip install \
        --no-cache-dir \
        --upgrade \
        pip \
        setuptools \
        wheel

ARG TF_WHEEL_FILE="tensorflow_cpu-2.20.0.dev0+selfbuilt-cp312-cp312-linux_x86_64.whl"
ARG TF_WHEEL_URL="https://github.com/leg3/tensorflow-nonavx/releases/download/v2.20.0-nonavx.1/tensorflow_cpu-2.20.0.dev0+selfbuilt-cp312-cp312-linux_x86_64.whl"
ARG TF_WHEEL_SHA256="b5c0ca166e83b67c0c038b84bca5b4f4426669da86187a047ed2b64e01dca949"

RUN curl -fL "${TF_WHEEL_URL}" -o "/tmp/${TF_WHEEL_FILE}" \
    && echo "${TF_WHEEL_SHA256}  /tmp/${TF_WHEEL_FILE}" | sha256sum -c - \
    && "${VIRTUAL_ENV}/bin/python" -m pip install \
        --no-cache-dir \
        "/tmp/${TF_WHEEL_FILE}" \
        pydot \
        scipy \
        pandas \
        Pillow \
        ipython \
    && rm -f "/tmp/${TF_WHEEL_FILE}"

COPY ar/SVR-AR.R /opt/svraas/model_runners/ar/SVR-AR.R
COPY arima/SVR-ARIMA.R /opt/svraas/model_runners/arima/SVR-ARIMA.R
COPY mlp/SVR-MLP.R /opt/svraas/model_runners/mlp/SVR-MLP.R
COPY lstm/SVR-LSTM.R /opt/svraas/model_runners/lstm/SVR-LSTM.R
COPY --chmod=0755 run_all.sh /opt/svraas/model_runners/run_all.sh
COPY --chmod=0755 run_forever.sh /opt/svraas/model_runners/run_forever.sh
COPY --chmod=0755 entrypoint.sh /opt/svraas/entrypoint.sh

ENTRYPOINT ["/opt/svraas/entrypoint.sh"]
CMD ["/opt/svraas/model_runners/run_forever.sh"]
