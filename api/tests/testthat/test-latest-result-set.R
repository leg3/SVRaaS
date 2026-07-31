# Test latest complete result-set cohort selection and assembly.

testthat::test_that("newest complete model month is selected", {

  may_candidates <- lapply(
    names(expected_models),
    make_artifact_candidate_fixture,
    latest_model_month = "2026-05-01"
  )

  june_candidates <- lapply(
    names(expected_models),
    make_artifact_candidate_fixture,
    latest_model_month = "2026-06-01"
  )

  testthat::expect_equal(
    find_latest_complete_model_month(
      c(may_candidates, june_candidates)
    ),
    as.Date("2026-06-01")
  )
})

testthat::test_that("newer incomplete model month is ignored", {

  may_candidates <- lapply(
    names(expected_models),
    make_artifact_candidate_fixture,
    latest_model_month = "2026-05-01"
  )

  june_candidates <- lapply(
    setdiff(names(expected_models), "lstm"),
    make_artifact_candidate_fixture,
    latest_model_month = "2026-06-01"
  )

  testthat::expect_equal(
    find_latest_complete_model_month(
      c(may_candidates, june_candidates)
    ),
    as.Date("2026-05-01")
  )
})

testthat::test_that("newest artifact is selected for a duplicated model", {

  candidates <- lapply(
    names(expected_models),
    make_artifact_candidate_fixture
  )

  newer_ar_candidate <- make_artifact_candidate_fixture(
    "ar",
    generated_at_utc = "2026-07-31T13:00:00Z"
  )

  selected_candidates <- select_latest_cohort_candidates(
    c(candidates, list(newer_ar_candidate)),
    as.Date("2026-06-01")
  )

  testthat::expect_identical(
    names(selected_candidates),
    names(expected_models)
  )

  testthat::expect_equal(
    selected_candidates$ar$run_id,
    "20260731T130000Z"
  )
})

testthat::test_that("incomplete-only candidates yield no model month", {

  candidates <- lapply(
    setdiff(names(expected_models), "lstm"),
    make_artifact_candidate_fixture
  )

  testthat::expect_identical(
    find_latest_complete_model_month(candidates),
    as.Date(NA_character_)
  )
})

testthat::test_that("incomplete model month yields no cohort selection", {

  candidates <- lapply(
    setdiff(names(expected_models), "lstm"),
    make_artifact_candidate_fixture
  )

  testthat::expect_identical(
    select_latest_cohort_candidates(
      candidates,
      as.Date("2026-06-01")
    ),
    list()
  )
})

testthat::test_that("complete artifacts are assembled into a result set", {

  artifact_root <- tempfile("svraas-artifacts-")
  dir.create(artifact_root)

  on.exit(
    unlink(artifact_root, recursive = TRUE),
    add = TRUE
  )

  candidates <- lapply(
    names(expected_models),
    make_artifact_candidate_fixture
  )

  invisible(
    lapply(
      candidates,
      function(candidate) {
        jsonlite::write_json(
          candidate$artifact,
          file.path(
            artifact_root,
            basename(candidate$artifact_file)
          ),
          auto_unbox = TRUE,
          pretty = TRUE
        )
      }
    )
  )

  result_set <- build_latest_result_set(artifact_root)

  testthat::expect_equal(
    result_set$latest_model_month,
    "2026-06-01"
  )

  testthat::expect_identical(
    names(result_set$artifacts),
    names(expected_models)
  )

  testthat::expect_equal(
    vapply(
      result_set$artifacts,
      function(artifact) artifact$metadata$model_name,
      character(1)
    ),
    expected_models
  )
})

testthat::test_that("empty artifact root yields no result set", {

  artifact_root <- tempfile("svraas-artifacts-")
  dir.create(artifact_root)

  on.exit(
    unlink(artifact_root, recursive = TRUE),
    add = TRUE
  )

  testthat::expect_null(
    build_latest_result_set(artifact_root)
  )
})

testthat::test_that("incomplete artifact root yields no result set", {

  artifact_root <- tempfile("svraas-artifacts-")
  dir.create(artifact_root)

  on.exit(
    unlink(artifact_root, recursive = TRUE),
    add = TRUE
  )

  candidates <- lapply(
    setdiff(names(expected_models), "lstm"),
    make_artifact_candidate_fixture
  )

  invisible(
    lapply(
      candidates,
      function(candidate) {
        jsonlite::write_json(
          candidate$artifact,
          file.path(
            artifact_root,
            basename(candidate$artifact_file)
          ),
          auto_unbox = TRUE,
          pretty = TRUE
        )
      }
    )
  )

  testthat::expect_null(
    build_latest_result_set(artifact_root)
  )
})
