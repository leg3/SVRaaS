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
