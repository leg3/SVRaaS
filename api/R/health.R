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

  # Confirm basic read access before attempting a real directory enumeration.
  root_accessible <- root_exists &&
    file.access(artifact_root, mode = 4L) == 0L

  # Force an actual directory read so stale or otherwise unusable NFS mounts
  # are reported as unhealthy. An empty but readable directory is valid.
  root_readable <- root_accessible &&
    isTRUE(
      tryCatch(
        {
          list.files(
            artifact_root,
            all.files = TRUE,
            no.. = TRUE
          )

          TRUE
        },
        warning = function(warning) FALSE,
        error = function(error) FALSE
      )
    )

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
