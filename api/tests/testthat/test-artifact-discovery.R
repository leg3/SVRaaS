# Test artifact-file discovery using an isolated temporary directory.
#
# The fake directory includes top-level JSON candidates plus files that
# discovery should ignore. No real SVRaaS artifacts are read or modified.

testthat::test_that("artifact files are discovered predictably", {

  artifact_root <- tempfile("svraas-artifacts-")
  dir.create(artifact_root)
  dir.create(file.path(artifact_root, "nested"))

  # Remove the temporary fixture directory when this test finishes.
  on.exit(
    unlink(artifact_root, recursive = TRUE, force = TRUE),
    add = TRUE
  )

  top_level_json <- c(
    file.path(artifact_root, "zeta.json"),
    file.path(artifact_root, "alpha.JSON")
  )

  # Create two top-level JSON candidates and two files that must be ignored.
  file.create(
    top_level_json,
    file.path(artifact_root, "notes.txt"),
    file.path(artifact_root, "nested", "ignored.json")
  )

  discovered_files <- list_artifact_files(artifact_root)

  testthat::expect_identical(
    discovered_files,
    sort(top_level_json)
  )
})
