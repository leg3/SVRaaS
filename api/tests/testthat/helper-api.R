# Start and control a real SVRaaS API process for HTTP endpoint tests.


# Stop a background test API process.
stop_test_api <- function(server) {

  if (server$process$is_alive()) {
    server$process$kill()
  }

  try(
    server$process$wait(timeout = 2000),
    silent = TRUE
  )

  invisible(NULL)
}


# Perform an HTTP request without converting error statuses into R errors.
request_test_api <- function(
    server,
    path,
    timeout_seconds = 5
) {

  httr2::request(
    paste0(server$base_url, path)
  ) |>
    httr2::req_timeout(timeout_seconds) |>
    httr2::req_error(
      is_error = function(response) FALSE
    ) |>
    httr2::req_perform()
}


# Wait until the background API accepts HTTP requests.
wait_for_test_api <- function(
    server,
    timeout_seconds = 10
) {

  deadline <- Sys.time() + timeout_seconds

  repeat {

    if (!server$process$is_alive()) {

      error_output <- paste(
        server$process$read_all_error_lines(),
        collapse = "\n"
      )

      stop(
        paste(
          "API process exited before becoming ready:",
          error_output
        ),
        call. = FALSE
      )
    }

    response <- tryCatch(
      request_test_api(
        server,
        path = "/health",
        timeout_seconds = 1
      ),
      error = function(error) NULL
    )

    if (!is.null(response)) {
      return(invisible(server))
    }

    if (Sys.time() >= deadline) {
      stop(
        "API did not become ready within 10 seconds.",
        call. = FALSE
      )
    }

    Sys.sleep(0.1)
  }
}


# Start the SVRaaS API in a separate R process.
start_test_api <- function(artifact_root) {

  api_dir <- normalizePath(
    testthat::test_path("..", ".."),
    winslash = "/",
    mustWork = TRUE
  )

  artifact_root <- normalizePath(
    artifact_root,
    winslash = "/",
    mustWork = FALSE
  )

  port <- httpuv::randomPort()

  process <- callr::r_bg(
    function(api_dir, artifact_root, port) {

      setwd(api_dir)

      Sys.setenv(
        SVRAAS_ARTIFACT_ROOT = artifact_root
      )

      parsed_api <- plumber2::api(
        "plumber.R",
        doc_type = NULL
      )

      plumber2::api_run(
        parsed_api,
        host = "127.0.0.1",
        port = port,
        block = TRUE,
        showcase = FALSE,
        silent = TRUE
      )
    },
    args = list(
      api_dir = api_dir,
      artifact_root = artifact_root,
      port = port
    ),
    stdout = "|",
    stderr = "|",
    supervise = TRUE
  )

  server <- list(
    process = process,
    base_url = sprintf(
      "http://127.0.0.1:%d",
      port
    )
  )

  tryCatch(
    {
      wait_for_test_api(server)
      server
    },
    error = function(error) {
      stop_test_api(server)
      stop(error)
    }
  )
}
