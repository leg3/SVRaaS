# ARIMA(p, d, q)
# Diagnostic ratio - UMCSI:VIX
#
# This script evaluates a grid of ARIMA(p,d,q) models using a leakage-safe,
# expanding-window rolling forecast setup, and reports forecast accuracy metrics
# (MSE/RMSE/MAE) on the held-out test period for horizons h = 1 and h = 3.
#
# There are THREE nested "loops", implemented functionally (purrr) instead of for-loops:
#   (1) model grid loop   : iterate over each (p,d,q) in arima_grid
#   (2) horizon loop      : iterate over each h in h_list
#   (3) time/rolling loop : iterate over each timestamp k inside test split
#
# Leakage safety rule:
#   For a target observation at time t (the split row k), the forecast "origin"
#   is set to t - h, so the model is fit only on data up through t - h (never t).

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

# Log transform the sentiment series
log_sentiment_series <- sentiment_series %>%
  mutate(log_value_sen = log(value))

# Log transform the volatility series
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

# Define start index of the test block in df_all. This is a "global" index
# relative to df_all.
i_test_start <- n - n_test + 1

# Subset df_all into training and test sets
train_df <- df_all[1:(i_test_start - 1), ]
test_df  <- df_all[i_test_start:n, ]

# Define rolling forecast horizons.  h = steps ahead
h_list <- c(1, 3)

# Define global start index for the test split inside of df_all Needed because
# the rolling code maps split row k -> global row in df_all: target_global_idx =
# split_start_idx + (k - 1) so we can slice df_all[1:origin_global_idx] for an
# expanding window.
test_start_idx <- i_test_start

# Grid specification for ARIMA (p, d, q) model_id is just a label used
# downstream in the results table. include_mean rule here: allow mean only when
# d == 0 (stationary around a mean).
arima_grid <- expand.grid(p = 1:3, d = 0:1, q = 1:3) %>%
  as_tibble() %>%
  mutate(include_mean = if_else(d == 0, TRUE, FALSE),
         model_id = paste0("ARIMA", p, d, q)) %>%
  select(model_id, p, d, q, include_mean)

# Define function to fit grid specification.   given (p,d,q,include_mean),
# return a function(ts_y) that fits that ARIMA spec.  This lets us pass the
# ARIMA spec around as a callable "fit_fun".
make_fit_arima <- function(p, d, q, include_mean) {
  function(ts_y) {
    forecast::Arima(ts_y, order = c(p, d, q), include.mean = include_mean)
  }
}

# Convert a df slice into a monthly ts object. Start is derived from df_slice so
# the ts timeline matches the slice.
make_ts_from_df_all <- function(df_slice) {
  ts(df_slice$y,
     start = c(year(min(df_slice$date)), month(min(df_slice$date))),
     frequency = 12)
}

# Rolling prediction function (INNERMOST LOOP: over time k within the test split)
#
# For each row k in split_df:
#   - Compute the global index of the target observation in df_all
#   - Set origin = target - h  (leakage-safe)
#   - Fit the model on df_all[1:origin] (expanding window)
#   - Forecast h steps ahead and take the h-th step as y_hat for the target date
roll_preds_arima_split <- function(df_all,
                                   split_df,
                                   split_start_idx,
                                   h,
                                   fit_fun,
                                   model_id = NA_character_) {
  purrr::map_dfr(seq_len(nrow(split_df)), function(k) {
    # Map split-local row k -> global row index of the target in df_all
    target_global_idx <- split_start_idx + (k - 1)

    # Leakage-safe origin: only allow training data up through (target - h)
    origin_global_idx <- target_global_idx - h

    # Expanding window training slice (from start of df_all through the origin)
    train_sub <- df_all[1:origin_global_idx, ]

    # Convert slice to monthly ts, fit ARIMA, then forecast h steps ahead
    ts_sub <- make_ts_from_df_all(train_sub)
    fit    <- fit_fun(ts_sub)
    fc     <- forecast::forecast(fit, h = h)

    # Use the h-step forecast and align it to the target observation
    y_hat <- as.numeric(fc$mean[h])

    tibble(
      model_id = model_id,
      date     = split_df$date[k],
      y        = split_df$y[k],
      y_hat    = y_hat,
      resid    = split_df$y[k] - y_hat
    )
  })
}

# Define function to calculate forecast accuracy metrics
calc_nn_metrics <- function(preds_tbl) {
  tibble(
    mse  = mean((preds_tbl$resid)^2, na.rm = TRUE),
    rmse = sqrt(mean((preds_tbl$resid)^2, na.rm = TRUE)),
    mae  = mean(abs(preds_tbl$resid), na.rm = TRUE)
  )
}

# Evaluate one ARIMA spec across:
#   - the test split
#   - both horizons (h_list)
#
# This is the MIDDLE LOOP (over horizons), and it calls the INNER LOOP
# (rolling over time) via roll_preds_arima_split().
eval_model_arima_nn <- function(df_all,
                                test_df,
                                test_start_idx,
                                h_list,
                                fit_fun,
                                model_id) {
  purrr::map_dfr(h_list, function(h) {
    # Rolling predictions for this horizon h
    preds_test <- roll_preds_arima_split(df_all, test_df, test_start_idx, h, fit_fun, model_id)

    # Summarize forecast accuracy metrics for test
    calc_nn_metrics(preds_test) %>%
      mutate(
        model_id = model_id,
        split = "test",
        horizon = h
      )
  }) %>%
    select(model_id, split, horizon, mse, rmse, mae)
}

# OUTERMOST LOOP (over the ARIMA grid): For each row of arima_grid:
#   - build a fit_fun for that (p,d,q,include_mean)
#   - evaluate it via eval_model_arima_nn()
#   - row-bind results into one long table
metrics_arima_nn_long <- purrr::pmap_dfr(arima_grid, function(model_id, p, d, q, include_mean) {
  fit_fun <- make_fit_arima(p, d, q, include_mean)

  eval_model_arima_nn(
    df_all,
    test_df,
    test_start_idx,
    h_list,
    fit_fun  = fit_fun,
    model_id = model_id
  )
})

# Reshape long -> wide for readability: One row per (model_id, horizon), with
# grouped test_* metric columns
metrics_arima_nn_wide <- metrics_arima_nn_long %>%
  pivot_wider(
    id_cols = c(model_id, horizon),
    names_from  = split,
    values_from = c(mse, rmse, mae),
    names_glue  = "{split}_{.value}"
  ) %>%
  select(model_id,
         horizon,
         test_mse,
         test_rmse,
         test_mae) %>%
  arrange(horizon, test_mae)

# CSV Export
write_csv(metrics_arima_nn_wide, "ARIMA Metrics FINAL.csv")
metrics_arima_nn_wide
