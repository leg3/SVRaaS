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


# Use the api directory as the service startup working directory.
api_dir <- normalizePath(
  getwd(),
  winslash = "/",
  mustWork = TRUE
)


# Load the API configuration helpers using the resolved api directory.
source(
  file.path(api_dir, "R", "config.R"),
  local = TRUE
)

# Load the API health-check helpers using the resolved api directory.
source(
  file.path(api_dir, "R", "health.R"),
  local = TRUE
)

# Read and validate the runtime configuration once when the API starts.
api_config <- load_config()

#* Report API and artifact-storage health.
#*
#* @get /health
#*
#* @serializer unboxedJSON
function(response) {

  # Build the health response from the configured artifact root.
  health_response <- build_health_response(
    api_config$artifact_root
  )

  # Return Service Unavailable when artifact storage cannot be accessed.
  if (!identical(health_response$status, "ok")) {
    response$status <- 503L
  }

  health_response
}

# Load the API latest-results helpers using the resolved api directory.
source(
  file.path(api_dir, "R", "results.R"),
  local = TRUE
)
