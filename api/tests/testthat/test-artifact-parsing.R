# Test artifact parsing with isolated temporary files.
#
# These fixtures verify successful nested JSON parsing and graceful handling
# of files that cannot be parsed or read.

testthat::test_that("valid artifact JSON is read without vector simplification", {

  artifact_file <- tempfile("svraas-artifact-", fileext = ".json")

  on.exit(
    unlink(artifact_file, force = TRUE),
    add = TRUE
  )

  writeLines(
    c(
      "{",
      '  "schema_version": "1.0",',
      '  "metadata": {',
      '    "model": "SVR-AR"',
      "  },",
      '  "horizons": [1, 3]',
      "}"
    ),
    artifact_file
  )

  artifact <- read_artifact_file(artifact_file)

  testthat::expect_identical(
    artifact$schema_version,
    "1.0"
  )

  testthat::expect_identical(
    artifact$metadata$model,
    "SVR-AR"
  )

  testthat::expect_type(
    artifact$horizons,
    "list"
  )
})

testthat::test_that("artifact read failures return NULL", {

  malformed_file <- tempfile("svraas-malformed-", fileext = ".json")

  on.exit(
    unlink(malformed_file, force = TRUE),
    add = TRUE
  )

  writeLines(
    '{"schema_version": "1.0"',
    malformed_file
  )

  missing_file <- tempfile("svraas-missing-", fileext = ".json")

  testthat::expect_null(
    read_artifact_file(malformed_file)
  )

  testthat::expect_null(
    suppressWarnings(
      read_artifact_file(missing_file)
    )
  )
})
