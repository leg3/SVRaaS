FROM rocker/r-ver:4.6.1

WORKDIR /opt/svraas

RUN install2.r --error --skipinstalled \
    forecast \
    tidyverse \
    lubridate \
    jsonlite \
    remotes

RUN Rscript -e 'remotes::install_github("leg3/pipewelder", upgrade = "never")'
