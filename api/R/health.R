# =============================================================================
# SVRaaS API Health Checks
#
# Purpose:
#   Evaluate API access to the artifact root and report runner build status.
#   Model status is advisory and never changes the API health HTTP status.
#   HTTP response handling remains in plumber.R.
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


# Read the optional runner status file without changing API availability.
read_model_suite_status <- function(artifact_root, root_readable = TRUE, now = Sys.time()) {

  unknown <- list(
    state = "unknown",
    heartbeat_fresh = FALSE
  )

  if (!root_readable) {
    unknown$reason <- "artifact_root_unavailable"
    return(unknown)
  }

  status_file <- file.path(artifact_root, "status.json")

  if (!file.exists(status_file)) {
    unknown$reason <- "missing_status"
    return(unknown)
  }

  # Invalid JSON or an I/O failure must not make a readable API unhealthy.
  report <- tryCatch(
    jsonlite::read_json(status_file, simplifyVector = FALSE),
    warning = function(warning) NULL,
    error = function(error) NULL
  )

  if (
    !is.list(report) ||
    !is.character(report$state) ||
    length(report$state) != 1L ||
    !report$state %in% c("building", "ready", "failed")
  ) {
    unknown$reason <- "invalid_status"
    return(unknown)
  }

  # Preserve diagnostic fields produced by model_runners/status.py. Do not
  # expose arbitrary fields from a status file through the health endpoint.
  result <- list(
    state = report$state,
    reported_state = report$state,
    heartbeat_fresh = FALSE
  )

  diagnostic_fields <- c(
    "current_model", "started_at_utc", "stage_started_at_utc",
    "updated_at_utc", "completed_at_utc", "failed_model",
    "error_code", "exit_code", "message"
  )

  for (field in diagnostic_fields) {
    if (!is.null(report[[field]])) {
      result[[field]] <- report[[field]]
    }
  }

  if (is.list(report$retry)) {
    result$retry <- report$retry[
      intersect(c("scheduled", "next_attempt_at_utc"), names(report$retry))
    ]
  }

  heartbeat <- report$heartbeat_at_utc

  # All timestamps written by the runner are UTC, accurate to the second.
  if (
    !is.character(heartbeat) ||
    length(heartbeat) != 1L ||
    is.na(heartbeat) ||
    !grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", heartbeat)
  ) {
    result$state <- "unknown"
    result$reason <- "invalid_status"
    return(result)
  }

  heartbeat_time <- tryCatch(
    suppressWarnings(
      as.POSIXct(heartbeat, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
    ),
    error = function(error) as.POSIXct(NA)
  )

  if (
    is.na(heartbeat_time) ||
    !identical(format(heartbeat_time, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"), heartbeat)
  ) {
    result$state <- "unknown"
    result$reason <- "invalid_status"
    return(result)
  }

  age_seconds <- as.numeric(difftime(now, heartbeat_time, units = "secs"))
  result$heartbeat_at_utc <- heartbeat
  result$heartbeat_age_seconds <- as.integer(round(age_seconds))

  # Allow modest clock skew. A heartbeat older than five minutes is stale.
  if (!is.finite(age_seconds) || age_seconds < -60) {
    result$state <- "unknown"
    result$reason <- "future_heartbeat"
  } else if (age_seconds > 300) {
    result$state <- "unknown"
    result$reason <- "stale_heartbeat"
  } else {
    result$heartbeat_fresh <- TRUE
  }

  result
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

  # Runner status is useful diagnostics, not an API health dependency.
  model_suite <- read_model_suite_status(
    artifact_root,
    root_readable = artifact_check$readable
  )

  # Preserve existing API health fields and add the advisory model-suite view.
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
    ),
    model_suite = model_suite
  )
}
