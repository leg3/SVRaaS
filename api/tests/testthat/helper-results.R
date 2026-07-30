# Load the production latest-results helpers before related tests run.
#
# test_path() resolves this path from tests/testthat regardless of the
# working directory used to launch the suite. local = TRUE keeps the
# sourced objects in testthat's isolated test environment.

source(
  testthat::test_path("..", "..", "R", "results.R"),
  local = TRUE
)
