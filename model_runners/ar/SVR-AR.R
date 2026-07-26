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

# Retreive data from FRED
volatility_series <- get_fred("VIXCLS", "1990-01-02", "2025-12-31")
sentiment_series <- get_fred("UMCSENT", "1990-01-01", "2025-12-31")

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

# Subset df_all into training and test sets
train_df <- df_all[1:(i_test_start - 1), ]
test_df  <- df_all[i_test_start:n, ]

# Rolling forecast
# Horizons
h_list <- c(1, 3)

# Define the AR order grid to evaluate
p_grid <- c(1:6)

# Define global start index for the test split inside df_all
# Needed because rolling code maps split row k -> global df_all row index:
# target_global_idx = split_start_idx + (k - 1)
test_start_idx <- i_test_start

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
metrics_arp_nn <- purrr::map_dfr(p_grid, function(p0) {
  purrr::map_dfr(h_list, function(h) {
    preds_test <- roll_preds_arp_split(df_all,
                                       test_df,
                                       test_start_idx,
                                       h = h,
                                       p = p0)

    m_test <- summarize_pred_metrics(preds_test)

    tibble(
      model_id = paste0("AR", p0),
      p = p0,
      horizon = h
    ) %>% bind_cols(
      m_test %>%
        rename(
          test_mse  = mse,
          test_rmse = rmse,
          test_mae  = mae
        )
    )
  })
}) %>%
  arrange(horizon, test_mae)

# CSV Export
write_csv(metrics_arp_nn, "AR Metrics FINAL.csv")
metrics_arp_nn
