# AR(p) Diagnostic ratio - UMCSI:VIX
#
# This script evaluates a grid of AR(p) models using a leakage-safe,
# expanding-window rolling forecast setup, and reports forecast accuracy metrics
# (MSE/RMSE/MAE) on the held-out test period for horizons h = 1 and h = 3.
#
# There are THREE nested "loops", implemented functionally (purrr) instead of
# for-loops: (1) model grid loop   : iterate over each p in p_grid (2) horizon
# loop      : iterate over each h in h_list (3) time/rolling loop : iterate over
# each timestamp k inside the test split
#
# Leakage safety rule: For a target observation at time t (the split row k), the
# forecast "origin" is set to t - h, so the model is fit only on data up through
# t - h (never t).

# Libraries
library(pipewelder)
library(tidyverse)
library(lubridate)
library(forecast)

# Set seed
set.seed(599)

# Resolve latest complete and aligned model window
resolve_model_window <- function(sentiment_series, data_end_date = Sys.Date()) {
  latest_complete_month <- as.Date(floor_date(data_end_date, "month") - months(1))
  latest_sentiment_month <- as.Date(max(sentiment_series$date, na.rm = TRUE))
  latest_model_month <- as.Date(min(latest_complete_month, latest_sentiment_month))
  latest_model_month_end <- as.Date(
    ceiling_date(latest_model_month, "month") - days(1)
  )

  list(
    data_end_date = as.Date(data_end_date),
    latest_complete_month = latest_complete_month,
    latest_sentiment_month = latest_sentiment_month,
    latest_model_month = latest_model_month,
    latest_model_month_end = latest_model_month_end
  )
}

# Set dates for expanding time window
umcsent_start_date <- "1990-01-01"
vix_start_date <- "1990-01-02"
data_end_date <- Sys.Date()

# Retrieve data from FRED
volatility_series <- get_fred("VIXCLS", vix_start_date, data_end_date)
sentiment_series <- get_fred("UMCSENT", umcsent_start_date, data_end_date)

# Resolve complete and aligned model window
model_window <- resolve_model_window(
  sentiment_series = sentiment_series,
  data_end_date = data_end_date
)

latest_complete_month <- model_window$latest_complete_month
latest_sentiment_month <- model_window$latest_sentiment_month
latest_model_month <- model_window$latest_model_month
latest_model_month_end <- model_window$latest_model_month_end

# Trim sentiment to latest usable month
sentiment_series <- sentiment_series %>%
  filter(date <= latest_model_month)

# Trim daily VIX before monthly averaging
volatility_series <- volatility_series %>%
  filter(date <= latest_model_month_end)

# Monthly mean of VIX (convert daily VIX to monthly average)
mean_volatility_series <- volatility_series %>%
  mutate(month = floor_date(date, "month")) %>%
  group_by(month) %>%
  summarize(mean_value = mean(value, na.rm = TRUE), .groups = "drop") %>%
  rename(date = month)

# Log transform the series
log_sentiment_series <- sentiment_series %>%
  mutate(log_value_sen = log(value))

# Log transform the volatility series (monthly mean VIX)
log_mean_volatility_series <- mean_volatility_series %>%
  mutate(log_value_mnvol = log(mean_value))

# Join and compute transformed ratio
log_diagnostic_ratio_series <- log_sentiment_series %>%
  inner_join(log_mean_volatility_series, by = "date") %>%
  select(-value, -mean_value) %>%
  mutate(log_ratio_raw = (log_value_sen - log_value_mnvol))

# Time-ordered partitions (monthly obs)
n_test <- 84   # ~7 years

# Create modeling dataframe (monthly, ordered, no missing y)
df_all <- log_diagnostic_ratio_series %>%
  select(date, y = log_ratio_raw) %>%
  arrange(date) %>%
  filter(!is.na(y))

# Total number of observations
n <- nrow(df_all)

# Sanity check: need enough observations to have train + test
stopifnot(n_test < n)

# Define start index of the test block in df_all
# This is a "global" index relative to df_all.
i_test_start <- n - n_test + 1

# Subset df_all into the fixed test set
test_df  <- df_all[i_test_start:n, ]

# Rolling forecast
# Horizons
h_list <- c(1, 3)

# Define the AR order grid to evaluate
p_grid <- c(1:6)

# Define AR(p) fit function: For stationary AR(p), we set d = 0 and force
# include.mean = TRUE.
fit_arp <- function(ts_y, p) {
  forecast::Arima(ts_y, order = c(p, 0, 0), include.mean = TRUE)
}

# Convert a df slice into a monthly ts object. Start is derived from df_slice so
# the ts timeline matches the slice.
make_ts_from_slice <- function(df_slice) {
  ts(df_slice$y,
     start = c(year(min(df_slice$date)), month(min(df_slice$date))),
     frequency = 12)
}

# Rolling prediction function (INNERMOST LOOP: over time k within the test split)
#
# For each row k in split_df:
#   - Compute the global index of the target observation in df_all
#   - Set origin = target - h  (leakage-safe)
#   - Fit AR(p) on df_all[1:origin] (expanding window)
#   - Forecast h steps ahead and take the h-th step as y_hat for the target date
roll_preds_arp_split <- function(df_all, split_df, split_start_idx, h, p) {
  purrr::map_dfr(seq_len(nrow(split_df)), function(k) {
    # Map split-local row k -> global row index of the target in df_all
    target_global_idx <- split_start_idx + (k - 1)

    # Leakage-safe origin: only allow training data up through (target - h)
    origin_global_idx <- target_global_idx - h

    # Expanding window training slice (from start of df_all through the origin)
    train_sub <- df_all[1:origin_global_idx, ]

    # Convert slice to monthly ts, fit AR(p), then forecast h steps ahead
    ts_sub <- make_ts_from_slice(train_sub)
    fit    <- fit_arp(ts_sub, p = p)
    fc     <- forecast::forecast(fit, h = h)

    # Use the h-step forecast and align it to the target observation
    y_hat <- as.numeric(fc$mean[h])

    tibble(
      date  = split_df$date[k],
      y     = split_df$y[k],
      y_hat = y_hat,
      resid = split_df$y[k] - y_hat
    )
  })
}

# Summarize rolling residuals into forecast accuracy metrics (MSE/RMSE/MAE)
summarize_pred_metrics <- function(pred_df) {
  pred_df %>%
    summarize(
      mse  = mean(resid^2, na.rm = TRUE),
      rmse = sqrt(mse),
      mae  = mean(abs(resid), na.rm = TRUE),
      .groups = "drop"
    )
}

# Test metrics
# OUTER LOOP  : iterate p over p_grid
# MIDDLE LOOP : iterate h over h_list
# INNER LOOP  : roll over time k via roll_preds_arp_split()
metrics_ar_result <- purrr::map_dfr(p_grid, function(p0) {
  purrr::map_dfr(h_list, function(h) {
    preds_test <- roll_preds_arp_split(df_all,
                                       test_df,
                                       i_test_start,
                                       h = h,
                                       p = p0)

    summarize_pred_metrics(preds_test) %>%
      transmute(
        model_id = paste0("AR", p0),
        p = p0,
        horizon = h,
        test_mse = mse,
        test_rmse = rmse,
        test_mae = mae
      )
  })
}) %>%
  arrange(horizon, test_mae)

# Select the best AR configuration for each forecast horizon
selected_ar_models <- metrics_ar_result %>%
  group_by(horizon) %>%
  slice_min(
    order_by = test_mae,
    n = 1,
    with_ties = FALSE
  ) %>%
  ungroup()

# Retain AR specifications for the selected models
selected_ar_specs <- selected_ar_models %>%
  select(
    model_id,
    horizon,
    p
  )

# Generate rolling predictions for the selected AR models
selected_ar_predictions <- purrr::pmap_dfr(
  selected_ar_specs,
  function(model_id, horizon, p) {
    roll_preds_arp_split(
      df_all = df_all,
      split_df = test_df,
      split_start_idx = i_test_start,
      h = horizon,
      p = p
    ) %>%
      transmute(
        date = as.character(date),
        horizon = horizon,
        model_id = model_id,
        actual_log_svr = y,
        predicted_log_svr = y_hat,
        residual_log_svr = resid
      )
  }
)

# Create a stable identifier and timestamp for this model run
run_timestamp <- Sys.time()

run_id <- format(
  run_timestamp,
  format = "%Y%m%dT%H%M%SZ",
  tz = "UTC"
)

generated_at_utc <- format(
  run_timestamp,
  format = "%Y-%m-%dT%H:%M:%SZ",
  tz = "UTC"
)

# Assemble the standardized AR output artifact
ar_output_artifact <- list(
  schema_version = "1.0",

  metadata = list(
    run_id = run_id,
    model_name = "SVR-AR",
    model_family = "statistical_time_series",
    target = "log_svr",
    selection_metric = "test_mae",
    selection_direction = "minimize",
    generated_at_utc = generated_at_utc,
    data_start_date = as.character(min(df_all$date)),
    latest_model_month = as.character(model_window$latest_model_month),
    latest_model_month_end = as.character(model_window$latest_model_month_end),
    training_window_type = "expanding",
    test_start_date = as.character(min(test_df$date)),
    test_end_date = as.character(max(test_df$date)),
    observation_count = nrow(df_all),
    test_observation_count = n_test
  ),

  metrics = metrics_ar_result,

  selected_models = selected_ar_models,

  predictions = selected_ar_predictions
)

# Create output directory for model artifacts
artifact_dir <- "artifacts"

dir.create(
  artifact_dir,
  recursive = TRUE,
  showWarnings = FALSE
)

# Build timestamped artifact path
artifact_path <- file.path(
  artifact_dir,
  paste0("ar_", run_id, ".json")
)

# Write standardized AR output artifact
jsonlite::write_json(
  ar_output_artifact,
  path = artifact_path,
  pretty = TRUE,
  auto_unbox = TRUE,
  dataframe = "rows",
  na = "null",
  null = "null",
  digits = NA
)

# Optional CSV validation export
# write_csv(metrics_ar_result, "AR Metrics - Model Runner.csv")

# Optional console validation
# metrics_ar_result
