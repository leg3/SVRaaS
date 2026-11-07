# Exercise the actual /health endpoint with fake status.json files.
# No runner processes, real model artifacts, or shared NFS mounts are involved.

make_suite_status <- function(state, heartbeat_at_utc) {
  list(
    state = state,
    current_model = if (identical(state, "building")) "SVR-MLP" else NULL,
    started_at_utc = "2026-11-07T10:00:00Z",
    updated_at_utc = "2026-11-07T10:02:00Z",
    heartbeat_at_utc = heartbeat_at_utc
  )
}

get_suite_health <- function(server) {
  response <- request_test_api(server, path = "/health")
  list(
    http_status = httr2::resp_status(response),
    body = jsonlite::fromJSON(
      httr2::resp_body_string(response),
      simplifyVector = FALSE
    )
  )
}

test_that("missing model status is unknown without affecting API health", {
  artifact_root <- withr::local_tempdir(pattern = "svraas-status-absent-")
  server <- start_test_api(artifact_root)
  withr::defer(stop_test_api(server))

  response <- get_suite_health(server)
  expect_identical(response$http_status, 200L)
  expect_identical(response$body$status, "ok")
  expect_identical(response$body$model_suite$state, "unknown")
  expect_identical(response$body$model_suite$reason, "missing_status")
  expect_false(response$body$model_suite$heartbeat_fresh)
})

test_that("fresh building, ready and failed states are reported", {
  artifact_root <- withr::local_tempdir(pattern = "svraas-status-current-")
  status_path <- file.path(artifact_root, "status.json")
  server <- start_test_api(artifact_root)
  withr::defer(stop_test_api(server))

  fresh <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  building <- make_suite_status("building", fresh)
  jsonlite::write_json(building, status_path, auto_unbox = TRUE)

  response <- get_suite_health(server)
  expect_identical(response$http_status, 200L)
  expect_identical(response$body$model_suite$state, "building")
  expect_identical(response$body$model_suite$reported_state, "building")
  expect_identical(response$body$model_suite$current_model, "SVR-MLP")
  expect_true(response$body$model_suite$heartbeat_fresh)

  ready <- make_suite_status("ready", fresh)
  ready$completed_at_utc <- fresh
  jsonlite::write_json(ready, status_path, auto_unbox = TRUE)

  response <- get_suite_health(server)
  expect_identical(response$http_status, 200L)
  expect_identical(response$body$model_suite$state, "ready")
  expect_identical(response$body$model_suite$completed_at_utc, fresh)

  failed <- make_suite_status("failed", fresh)
  failed$failed_model <- "SVR-LSTM"
  failed$error_code <- "model_execution_failed"
  failed$exit_code <- 1L
  failed$retry <- list(scheduled = TRUE, next_attempt_at_utc = "2026-11-07T11:02:00Z")
  jsonlite::write_json(failed, status_path, auto_unbox = TRUE)

  response <- get_suite_health(server)
  expect_identical(response$http_status, 200L)
  expect_identical(response$body$model_suite$state, "failed")
  expect_identical(response$body$model_suite$failed_model, "SVR-LSTM")
  expect_identical(response$body$model_suite$error_code, "model_execution_failed")
  expect_true(response$body$model_suite$retry$scheduled)
})

test_that("stale heartbeat preserves last reported state but not liveness", {
  artifact_root <- withr::local_tempdir(pattern = "svraas-status-stale-")
  stale <- format(Sys.time() - 3600, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  jsonlite::write_json(
    make_suite_status("building", stale),
    file.path(artifact_root, "status.json"),
    auto_unbox = TRUE
  )

  server <- start_test_api(artifact_root)
  withr::defer(stop_test_api(server))
  response <- get_suite_health(server)

  expect_identical(response$http_status, 200L)
  expect_identical(response$body$status, "ok")
  expect_identical(response$body$model_suite$state, "unknown")
  expect_identical(response$body$model_suite$reported_state, "building")
  expect_identical(response$body$model_suite$reason, "stale_heartbeat")
  expect_false(response$body$model_suite$heartbeat_fresh)
})

test_that("malformed, invalid and implausibly future status is unknown", {
  artifact_root <- withr::local_tempdir(pattern = "svraas-status-invalid-")
  status_path <- file.path(artifact_root, "status.json")
  server <- start_test_api(artifact_root)
  withr::defer(stop_test_api(server))

  writeLines("{not valid JSON", status_path)
  response <- get_suite_health(server)
  expect_identical(response$http_status, 200L)
  expect_identical(response$body$model_suite$state, "unknown")
  expect_identical(response$body$model_suite$reason, "invalid_status")

  jsonlite::write_json(
    list(state = "building", heartbeat_at_utc = "not a timestamp"),
    status_path,
    auto_unbox = TRUE
  )
  response <- get_suite_health(server)
  expect_identical(response$body$model_suite$reported_state, "building")
  expect_identical(response$body$model_suite$reason, "invalid_status")

  future <- format(Sys.time() + 3600, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  jsonlite::write_json(
    make_suite_status("ready", future),
    status_path,
    auto_unbox = TRUE
  )
  response <- get_suite_health(server)
  expect_identical(response$body$model_suite$state, "unknown")
  expect_identical(response$body$model_suite$reported_state, "ready")
  expect_identical(response$body$model_suite$reason, "future_heartbeat")
})

test_that("unavailable artifact root still controls HTTP 503", {
  artifact_root <- file.path(
    withr::local_tempdir(pattern = "svraas-status-unavailable-"),
    "missing"
  )
  server <- start_test_api(artifact_root)
  withr::defer(stop_test_api(server))
  response <- get_suite_health(server)

  expect_identical(response$http_status, 503L)
  expect_identical(response$body$status, "error")
  expect_identical(response$body$model_suite$state, "unknown")
  expect_identical(response$body$model_suite$reason, "artifact_root_unavailable")
})

test_that("status.json does not change an empty results cohort response", {
  artifact_root <- withr::local_tempdir(pattern = "svraas-status-results-")
  jsonlite::write_json(
    make_suite_status("ready", format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")),
    file.path(artifact_root, "status.json"),
    auto_unbox = TRUE
  )
  server <- start_test_api(artifact_root)
  withr::defer(stop_test_api(server))
  response <- request_test_api(server, path = "/v1/results/latest")
  body <- jsonlite::fromJSON(httr2::resp_body_string(response), simplifyVector = FALSE)

  expect_identical(httr2::resp_status(response), 503L)
  expect_identical(body$error, "latest_results_unavailable")
})
