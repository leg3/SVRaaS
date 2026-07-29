# =============================================================================
# SVRaaS API Configuration
#
# Purpose:
#   Load and validate the runtime configuration used by the SVRaaS API.
#
#   The API reads model artifacts from the directory specified by the
#   SVRAAS_ARTIFACT_ROOT environment variable. The path must be absolute so API
#   behavior never depends on the process's current working directory.
#
#   This file validates the configuration but does not require the artifact
#   directory to already exist. Directory availability and readability will be
#   checked later by the API health endpoint.
# =============================================================================


# Determine whether a path is absolute on Unix-like or Windows systems.
is_absolute_path <- function(path) {

  # Accept Unix-style absolute paths such as /srv/svraas/artifacts,
  # Windows UNC paths such as \\server\share, and Windows drive paths
  # such as C:\svraas\artifacts.
  startsWith(path, "/") ||
    startsWith(path, "\\\\") ||
    grepl("^[A-Za-z]:[/\\\\]", path)
}


# Load and validate the API's runtime configuration.
load_config <- function() {

  # Read the artifact root from the environment and remove surrounding
  # whitespace. Use an empty string when the variable is not configured.
  artifact_root <- trimws(
    Sys.getenv("SVRAAS_ARTIFACT_ROOT", unset = "")
  )

  # Stop startup when no artifact root has been configured.
  if (!nzchar(artifact_root)) {
    stop(
      "SVRAAS_ARTIFACT_ROOT must be configured.",
      call. = FALSE
    )
  }

  # Require an absolute path so artifact resolution does not depend on
  # whichever working directory was used to start the API.
  if (!is_absolute_path(artifact_root)) {
    stop(
      "SVRAAS_ARTIFACT_ROOT must be an absolute path.",
      call. = FALSE
    )
  }

  # Return the validated configuration as a named list. Normalize path
  # separators for consistent downstream use without requiring the
  # directory to exist yet.
  list(
    artifact_root = normalizePath(
      artifact_root,
      winslash = "/",
      mustWork = FALSE
    )
  )
}
