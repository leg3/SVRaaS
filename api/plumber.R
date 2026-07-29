# =============================================================================
# SVRaaS Plumber2 API Entrypoint
#
# Purpose:
#   Bootstrap the read-only internal API used to expose SVRaaS model results.
#
#   This file locates supporting API code relative to its own location, loads
#   runtime configuration once during startup, and will define the available
#   HTTP endpoints.
# =============================================================================


# Resolve the api directory from this file's location so startup does not
# depend on the R process's current working directory.
api_file <- normalizePath(
  sys.frame(1)$ofile,
  winslash = "/",
  mustWork = TRUE
)

api_dir <- dirname(api_file)


# Load the API configuration helpers using the resolved api directory.
source(
  file.path(api_dir, "R", "config.R"),
  local = TRUE
)


# Read and validate the runtime configuration once when the API starts.
api_config <- load_config()
