# =============================================================================
# SVRaaS API Health Checks
#
# Purpose:
#   Evaluate whether the API can access the configured model-artifact directory.
#
#   These helpers build the response data for GET /health without reading,
#   changing, or exposing individual artifact files. HTTP response handling will
#   remain in plumber.R so health logic stays separate from transport logic.
# =============================================================================


# Check whether the configured artifact root exists and is readable.
check_artifact_root <- function(artifact_root) {

  # Confirm that the configured path exists and represents a directory.
  root_exists <- dir.exists(artifact_root)

  # Check read access only when the directory exists.
  root_readable <- root_exists &&
    file.access(artifact_root, mode = 4L) == 0L

  # Return the dependency status without exposing the filesystem path.
  list(
    status = if (root_readable) "ok" else "error",
    exists = root_exists,
    readable = root_readable
  )
}


# Build the complete health response returned by the API.
build_health_response <- function(artifact_root) {

  # Evaluate the artifact storage dependency.
  artifact_check <- check_artifact_root(artifact_root)

  # The API is healthy only when its artifact root is available and readable.
  api_status <- if (identical(artifact_check$status, "ok")) {
    "ok"
  } else {
    "error"
  }

  # Return a timestamped, JSON-ready health response.
  list(
    status = api_status,
    service = "svraas-api",
    checked_at = format(
      Sys.time(),
      format = "%Y-%m-%dT%H:%M:%SZ",
      tz = "UTC"
    ),
    checks = list(
      artifact_root = artifact_check
    )
  )
}
