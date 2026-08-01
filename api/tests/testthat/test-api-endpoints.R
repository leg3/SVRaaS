test_that("GET /health returns 200 for a readable artifact root", {

  artifact_root <- normalizePath(
    withr::local_tempdir(
      pattern = "svraas-api-health-"
    ),
    winslash = "/",
    mustWork = TRUE
  )

  server <- start_test_api(artifact_root)

  withr::defer(
    stop_test_api(server)
  )

  response <- request_test_api(
    server,
    path = "/health"
  )

  response_text <- httr2::resp_body_string(response)

  response_body <- jsonlite::fromJSON(
    response_text,
    simplifyVector = FALSE
  )

  expect_equal(
    httr2::resp_status(response),
    200L
  )

  expect_identical(
    response_body$status,
    "ok"
  )

  expect_identical(
    response_body$service,
    "svraas-api"
  )

  expect_true(
    response_body$checks$artifact_root$exists
  )

  expect_true(
    response_body$checks$artifact_root$readable
  )

  expect_false(
    grepl(
      artifact_root,
      response_text,
      fixed = TRUE
    )
  )
})

test_that("GET /health returns 503 for a missing artifact root", {

  artifact_root <- normalizePath(
    file.path(
      withr::local_tempdir(
        pattern = "svraas-api-missing-"
      ),
      "missing"
    ),
    winslash = "/",
    mustWork = FALSE
  )

  server <- start_test_api(artifact_root)

  withr::defer(
    stop_test_api(server)
  )

  response <- request_test_api(
    server,
    path = "/health"
  )

  response_text <- httr2::resp_body_string(response)

  response_body <- jsonlite::fromJSON(
    response_text,
    simplifyVector = FALSE
  )

  expect_equal(
    httr2::resp_status(response),
    503L
  )

  expect_identical(
    response_body$status,
    "error"
  )

  expect_identical(
    response_body$service,
    "svraas-api"
  )

  expect_false(
    response_body$checks$artifact_root$exists
  )

  expect_false(
    response_body$checks$artifact_root$readable
  )

  expect_false(
    grepl(
      artifact_root,
      response_text,
      fixed = TRUE
    )
  )
})

test_that("GET /v1/results/latest returns 503 without a complete cohort", {

  artifact_root <- normalizePath(
    withr::local_tempdir(
      pattern = "svraas-api-empty-"
    ),
    winslash = "/",
    mustWork = TRUE
  )

  server <- start_test_api(artifact_root)

  withr::defer(
    stop_test_api(server)
  )

  response <- request_test_api(
    server,
    path = "/v1/results/latest"
  )

  response_text <- httr2::resp_body_string(response)

  response_body <- jsonlite::fromJSON(
    response_text,
    simplifyVector = FALSE
  )

  expect_equal(
    httr2::resp_status(response),
    503L
  )

  expect_identical(
    response_body$error,
    "latest_results_unavailable"
  )

  expect_identical(
    response_body$message,
    "A complete aligned result set is not available."
  )

  expect_false(
    grepl(
      artifact_root,
      response_text,
      fixed = TRUE
    )
  )
})

test_that("GET /v1/results/latest returns 200 for a complete cohort", {

  artifact_root <- normalizePath(
    withr::local_tempdir(
      pattern = "svraas-api-complete-"
    ),
    winslash = "/",
    mustWork = TRUE
  )

  run_id <- "20260731T120000Z"
  generated_at_utc <- "2026-07-31T12:00:00Z"

  for (model_key in names(expected_models)) {

    artifact <- make_valid_artifact_fixture()

    artifact$metadata$run_id <- run_id
    artifact$metadata$model_name <- unname(
      expected_models[[model_key]]
    )
    artifact$metadata$generated_at_utc <- generated_at_utc
    artifact$metadata$latest_model_month <- "2026-06-01"

    jsonlite::write_json(
      artifact,
      path = file.path(
        artifact_root,
        paste0(model_key, "_", run_id, ".json")
      ),
      auto_unbox = TRUE,
      pretty = TRUE
    )
  }

  server <- start_test_api(artifact_root)

  withr::defer(
    stop_test_api(server)
  )

  response <- request_test_api(
    server,
    path = "/v1/results/latest"
  )

  response_text <- httr2::resp_body_string(response)

  response_body <- jsonlite::fromJSON(
    response_text,
    simplifyVector = FALSE
  )

  returned_model_names <- vapply(
    response_body$artifacts,
    function(artifact) artifact$metadata$model_name,
    character(1)
  )

  expect_equal(
    httr2::resp_status(response),
    200L
  )

  expect_identical(
    httr2::resp_header(response, "content-type"),
    "application/json"
  )

  expect_identical(
    response_body$latest_model_month,
    "2026-06-01"
  )

  expect_identical(
    names(response_body$artifacts),
    names(expected_models)
  )

  expect_identical(
    unname(returned_model_names),
    unname(expected_models)
  )

  expect_false(
    grepl(
      artifact_root,
      response_text,
      fixed = TRUE
    )
  )
})