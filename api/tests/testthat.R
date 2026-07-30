# Entry point for the SVRaaS API automated test suite.
#
# Development dependency:
#   install.packages("testthat")
#
# Run from the api directory with:
#   source("tests/testthat.R")
#
# test_dir() discovers and runs test-*.R files under tests/testthat.
# stop_on_failure = TRUE stops the suite as soon as a test fails.

testthat::test_dir(
  "tests/testthat",
  reporter = "summary",
  stop_on_failure = TRUE
)
