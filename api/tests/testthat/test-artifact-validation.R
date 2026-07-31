# Test artifact structure, metadata, and filename validation.

testthat::test_that("supported artifact structure is accepted", {

  artifact <- make_valid_artifact_fixture()

  testthat::expect_true(
    has_supported_artifact_structure(artifact)
  )
})

testthat::test_that("unsupported artifact structures are rejected", {

  missing_section <- make_valid_artifact_fixture()
  missing_section$predictions <- NULL

  invalid_schema_type <- make_valid_artifact_fixture()
  invalid_schema_type$schema_version <- 1.0

  invalid_schema_length <- make_valid_artifact_fixture()
  invalid_schema_length$schema_version <- c("1.0", "1.0")

  unsupported_schema <- make_valid_artifact_fixture()
  unsupported_schema$schema_version <- "2.0"

  invalid_section_type <- make_valid_artifact_fixture()
  invalid_section_type$metrics <- "not-a-list"

  testthat::expect_false(
    has_supported_artifact_structure("not-an-artifact")
  )

  testthat::expect_false(
    has_supported_artifact_structure(missing_section)
  )

  testthat::expect_false(
    has_supported_artifact_structure(invalid_schema_type)
  )

  testthat::expect_false(
    has_supported_artifact_structure(invalid_schema_length)
  )

  testthat::expect_false(
    has_supported_artifact_structure(unsupported_schema)
  )

  testthat::expect_false(
    has_supported_artifact_structure(invalid_section_type)
  )
})

testthat::test_that("supported artifact metadata is accepted", {

  artifact <- make_valid_artifact_fixture()

  testthat::expect_true(
    has_supported_artifact_metadata(artifact)
  )
})

testthat::test_that("unsupported artifact metadata is rejected", {

  invalid_structure <- make_valid_artifact_fixture()
  invalid_structure$metrics <- "not-a-list"

  missing_field <- make_valid_artifact_fixture()
  missing_field$metadata$latest_model_month <- NULL

  invalid_type <- make_valid_artifact_fixture()
  invalid_type$metadata$run_id <- 1

  invalid_length <- make_valid_artifact_fixture()
  invalid_length$metadata$model_name <- c("SVR-AR", "SVR-ARIMA")

  missing_value <- make_valid_artifact_fixture()
  missing_value$metadata$generated_at_utc <- NA_character_

  empty_value <- make_valid_artifact_fixture()
  empty_value$metadata$latest_model_month <- ""

  unsupported_model <- make_valid_artifact_fixture()
  unsupported_model$metadata$model_name <- "SVR-UNKNOWN"

  invalid_run_id <- make_valid_artifact_fixture()
  invalid_run_id$metadata$run_id <- "2026-07-31T120000Z"

  invalid_timestamp <- make_valid_artifact_fixture()
  invalid_timestamp$metadata$generated_at_utc <- "2026-07-31 12:00:00Z"

  invalid_model_month <- make_valid_artifact_fixture()
  invalid_model_month$metadata$latest_model_month <- "2026-06-30"

  mismatched_run_id <- make_valid_artifact_fixture()
  mismatched_run_id$metadata$run_id <- "20260731T120001Z"

  testthat::expect_false(
    has_supported_artifact_metadata(invalid_structure)
  )

  testthat::expect_false(
    has_supported_artifact_metadata(missing_field)
  )

  testthat::expect_false(
    has_supported_artifact_metadata(invalid_type)
  )

  testthat::expect_false(
    has_supported_artifact_metadata(invalid_length)
  )

  testthat::expect_false(
    has_supported_artifact_metadata(missing_value)
  )

  testthat::expect_false(
    has_supported_artifact_metadata(empty_value)
  )

  testthat::expect_false(
    has_supported_artifact_metadata(unsupported_model)
  )

  testthat::expect_false(
    has_supported_artifact_metadata(invalid_run_id)
  )

  testthat::expect_false(
    has_supported_artifact_metadata(invalid_timestamp)
  )

  testthat::expect_false(
    has_supported_artifact_metadata(invalid_model_month)
  )

  testthat::expect_false(
    has_supported_artifact_metadata(mismatched_run_id)
  )
})

testthat::test_that("matching artifact filename is accepted", {

  artifact <- make_valid_artifact_fixture()

  testthat::expect_true(
    has_matching_artifact_filename(
      file.path("artifacts", "ar_20260731T120000Z.json"),
      artifact
    )
  )
})

testthat::test_that("nonmatching artifact filenames are rejected", {

  artifact <- make_valid_artifact_fixture()

  invalid_metadata <- make_valid_artifact_fixture()
  invalid_metadata$metadata$run_id <- "20260731T120001Z"

  testthat::expect_false(
    has_matching_artifact_filename(
      file.path("artifacts", "ar_20260731T120000Z.json"),
      invalid_metadata
    )
  )

  testthat::expect_false(
    has_matching_artifact_filename(
      file.path("artifacts", "arima_20260731T120000Z.json"),
      artifact
    )
  )

  testthat::expect_false(
    has_matching_artifact_filename(
      file.path("artifacts", "ar_20260731T120001Z.json"),
      artifact
    )
  )

  testthat::expect_false(
    has_matching_artifact_filename(
      file.path("artifacts", "ar_20260731T120000Z.JSON"),
      artifact
    )
  )
})
