# =============================================================================
# SVRaaS Latest Results Helpers
#
# Purpose:
#   Identify the newest complete set of model artifacts that share the same
#   latest model month.
#
#   These helpers build the response data for GET /v1/results/latest. HTTP
#   response handling will remain in plumber.R so artifact-selection logic
#   stays separate from transport logic.
# =============================================================================

# Define the complete set of models required for a publishable result cohort.
expected_models <- c(
  ar = "SVR-AR",
  arima = "SVR-ARIMA",
  mlp = "SVR-MLP",
  lstm = "SVR-LSTM"
)

# Define the artifact schema versions supported by this API.
supported_schema_versions <- "1.0"

# List candidate JSON artifacts in the configured artifact root.
list_artifact_files <- function(artifact_root) {

  # Return file paths in a stable order for predictable processing.
  sort(
    list.files(
      path = artifact_root,
      pattern = "\\.json$",
      full.names = TRUE,
      recursive = FALSE,
      ignore.case = TRUE
    )
  )
}

# Read an artifact without allowing malformed JSON to stop cohort discovery.
read_artifact_file <- function(artifact_file) {
  
  tryCatch(
    jsonlite::read_json(
      path = artifact_file,
      simplifyVector = FALSE
    ),
    error = function(error) NULL
  )
}

# Check whether an artifact has the complete supported top-level structure.
has_supported_artifact_structure <- function(artifact) {
  
  required_sections <- c(
    "schema_version",
    "metadata",
    "metrics",
    "selected_models",
    "predictions"
  )
  
  # Reject missing, incomplete, or unsupported artifact structures.
  is.list(artifact) &&
    all(required_sections %in% names(artifact)) &&
    is.character(artifact$schema_version) &&
    length(artifact$schema_version) == 1L &&
    artifact$schema_version %in% supported_schema_versions &&
    is.list(artifact$metadata) &&
    is.list(artifact$metrics) &&
    is.list(artifact$selected_models) &&
    is.list(artifact$predictions)
}

# Check whether an artifact contains valid metadata for cohort selection.
has_supported_artifact_metadata <- function(artifact) {
  
  required_metadata <- c(
    "run_id",
    "model_name",
    "generated_at_utc",
    "latest_model_month"
  )
  
  # Reject artifacts without the supported structure or required metadata.
  if (
    !has_supported_artifact_structure(artifact) ||
    !all(required_metadata %in% names(artifact$metadata))
  ) {
    return(FALSE)
  }
  
  metadata <- artifact$metadata
  
  # Require every selection field to be one non-empty character value.
  metadata_is_scalar <- vapply(
    metadata[required_metadata],
    function(value) {
      is.character(value) &&
        length(value) == 1L &&
        !is.na(value) &&
        nzchar(value)
    },
    logical(1)
  )
  
  if (!all(metadata_is_scalar)) {
    return(FALSE)
  }
  
  # Use run_id only as an internal sanity check against the UTC timestamp.
  expected_run_id <- gsub(
    pattern = "[-:]",
    replacement = "",
    x = metadata$generated_at_utc
  )
  
  metadata$model_name %in% unname(expected_models) &&
    grepl(
      "^[0-9]{8}T[0-9]{6}Z$",
      metadata$run_id
    ) &&
    grepl(
      "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$",
      metadata$generated_at_utc
    ) &&
    grepl(
      "^[0-9]{4}-[0-9]{2}-01$",
      metadata$latest_model_month
    ) &&
    identical(metadata$run_id, expected_run_id)
}

# Check whether an artifact filename agrees with its model and run metadata.
has_matching_artifact_filename <- function(artifact_file, artifact) {
  
  if (!has_supported_artifact_metadata(artifact)) {
    return(FALSE)
  }
  
  model_key <- names(expected_models)[
    match(artifact$metadata$model_name, expected_models)
  ]
  
  expected_filename <- paste0(
    model_key,
    "_",
    artifact$metadata$run_id,
    ".json"
  )
  
  identical(
    basename(artifact_file),
    unname(expected_filename)
  )
}

# Build a validated artifact candidate for cohort selection.
build_artifact_candidate <- function(artifact_file) {
  
  artifact <- read_artifact_file(artifact_file)
  
  # Reject unreadable artifacts or artifacts that fail any sanity check.
  if (!has_matching_artifact_filename(artifact_file, artifact)) {
    return(NULL)
  }
  
  generated_at_utc <- as.POSIXct(
    artifact$metadata$generated_at_utc,
    format = "%Y-%m-%dT%H:%M:%SZ",
    tz = "UTC"
  )
  
  latest_model_month <- as.Date(
    artifact$metadata$latest_model_month,
    format = "%Y-%m-%d"
  )
  
  # Reject metadata that matches the format but is not a real date or time.
  if (is.na(generated_at_utc) || is.na(latest_model_month)) {
    return(NULL)
  }
  
  list(
    artifact_file = artifact_file,
    model_name = artifact$metadata$model_name,
    run_id = artifact$metadata$run_id,
    generated_at_utc = generated_at_utc,
    latest_model_month = latest_model_month,
    artifact = artifact
  )
}

# Build validated candidates from all JSON files in the artifact root.
build_artifact_candidates <- function(artifact_root) {
  
  artifact_files <- list_artifact_files(artifact_root)
  
  candidates <- lapply(
    artifact_files,
    build_artifact_candidate
  )
  
  # Remove unreadable or invalid artifacts from further consideration.
  Filter(
    function(candidate) !is.null(candidate),
    candidates
  )
}
