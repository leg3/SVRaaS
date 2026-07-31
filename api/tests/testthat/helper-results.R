# Load the production latest-results helpers before related tests run.
#
# test_path() resolves this path from tests/testthat regardless of the
# working directory used to launch the suite. local = TRUE keeps the
# sourced objects in testthat's isolated test environment.

source(
  testthat::test_path("..", "..", "R", "results.R"),
  local = TRUE
)

# Build a valid artifact fixture for validation tests.
make_valid_artifact_fixture <- function() {

  list(
    schema_version = "1.0",
    metadata = list(
      run_id = "20260731T120000Z",
      model_name = "SVR-AR",
      generated_at_utc = "2026-07-31T12:00:00Z",
      latest_model_month = "2026-06-01"
    ),
    metrics = list(),
    selected_models = list(),
    predictions = list()
  )
}

# Build a validated in-memory candidate for cohort-selection tests.
make_artifact_candidate_fixture <- function(
    model_key,
    latest_model_month = "2026-06-01",
    generated_at_utc = "2026-07-31T12:00:00Z"
) {

  generated_time <- as.POSIXct(
    generated_at_utc,
    format = "%Y-%m-%dT%H:%M:%SZ",
    tz = "UTC"
  )

  run_id <- format(
    generated_time,
    "%Y%m%dT%H%M%SZ",
    tz = "UTC"
  )

  model_name <- unname(expected_models[[model_key]])

  artifact <- make_valid_artifact_fixture()
  artifact$metadata$run_id <- run_id
  artifact$metadata$model_name <- model_name
  artifact$metadata$generated_at_utc <- generated_at_utc
  artifact$metadata$latest_model_month <- latest_model_month

  list(
    artifact_file = file.path(
      "artifacts",
      paste0(model_key, "_", run_id, ".json")
    ),
    model_name = model_name,
    run_id = run_id,
    generated_at_utc = generated_time,
    latest_model_month = as.Date(latest_model_month),
    artifact = artifact
  )
}
