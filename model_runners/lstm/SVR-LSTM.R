# LSTM MODEL
# Diagnostic ratio - UMCSI:VIX
#
# This script evaluates a grid of simple recurrent neural nets (LSTM) using
# leakage-safe preprocessing and NN-style metrics (MSE/RMSE/MAE) on validation
# and test splits for horizons h = 1 and h = 3.
#
# There are TWO nested loops:
#   (1) lag-window loop : iterate over each lag_window in lag_grid
#   (2) horizon loop    : iterate over each forecast horizon h in horizons
#
# Leakage safety rule (preprocessing):
#   Standardization parameters (mu, sd) are fit on TRAIN only, then applied to
#   val/test. No information from val/test is used to scale train.
#
# Interpretation note:
#   Models are trained/evaluated on SCALED log(SVR), but we also compute
#   "raw-scale" error metrics by inverse-transforming predictions back to the
#   original log(SVR) scale (y_raw, y_hat_raw).

# Libraries
library(pipewelder)
library(tidyverse)
library(lubridate)
library(keras3)

# Set seed
set.seed(599)

# Resolve latest complete and aligned model window
resolve_model_window <- function(sentiment_series, data_end_date = Sys.Date()) {
  latest_complete_month <- as.Date(floor_date(data_end_date, "month") - months(1))
  latest_sentiment_month <- as.Date(max(sentiment_series$date, na.rm = TRUE))
  latest_model_month <- as.Date(min(latest_complete_month, latest_sentiment_month))
  latest_model_month_end <- as.Date(ceiling_date(latest_model_month, "month") - days(1))

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
vix_start_date  <- "1990-01-02"
data_end_date   <- Sys.Date()

# Retreive data from FRED
volatility_series <- get_fred("VIXCLS", vix_start_date, data_end_date)
sentiment_series  <- get_fred("UMCSENT", umcsent_start_date, data_end_date)

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

# Monthly mean of VIX
mean_volatility_series <- volatility_series %>%
  mutate(month = floor_date(date, "month")) %>%
  group_by(month) %>%
  summarize(mean_value = mean(value, na.rm = TRUE), .groups = "drop") %>%
  rename(date = month)

# Log transform the series
log_sentiment_series <- sentiment_series %>%
  mutate(log_value_sen = log(value))

# Log transform the monthly-mean volatility series
log_mean_volatility_series <- mean_volatility_series %>%
  mutate(log_value_mnvol = log(mean_value))

# Join and compute transformed ratio
log_diagnostic_ratio_series <- log_sentiment_series %>%
  inner_join(log_mean_volatility_series, by = "date") %>%
  select(-value, -mean_value) %>%
  mutate(log_ratio_raw = (log_value_sen - log_value_mnvol))


# Partitioning (monthly obs)
n_test <- 84   # ~7 years

# Create modeling dataframe (monthly, ordered, no missing y)
df_all <- log_diagnostic_ratio_series %>%
  select(date, y_raw = log_ratio_raw) %>%
  arrange(date) %>%
  filter(!is.na(y_raw))

# Total number of observations
n <- nrow(df_all)

# Sanity check: need enough observations to have train + test
stopifnot(n_test < n)

# Compute global index for the start of the test block
i_test_start <- n - n_test + 1

# Subset df_all into training and test sets
train_df <- df_all[1:(i_test_start - 1), ]
test_df  <- df_all[i_test_start:n, ]

# Fit scaler parameters on TRAIN only (leakage-safe)
scaler_mu <- mean(train_df$y_raw, na.rm = TRUE)
scaler_sd <- sd(train_df$y_raw, na.rm = TRUE)

# Sanity check: scaler must be finite and sd must be > 0
stopifnot(is.finite(scaler_mu), is.finite(scaler_sd), scaler_sd > 0)

# Scale each split using TRAIN mu/sd
train_df <- train_df %>%
  mutate(y_scaled = (y_raw - scaler_mu) / scaler_sd)

test_df <- test_df %>%
  mutate(y_scaled = (y_raw - scaler_mu) / scaler_sd)

# make_supervised()
# Given a univariate series, build:
#   X : 3D array for LSTM input
#       (samples, timesteps = lag_window, features = 1)
#   y : numeric vector of targets at the specified forecast horizon
#
# Window ordering: oldest -> newest within the lag window
make_supervised <- function(series_values,
                            lag_window,
                            forecast_horizon) {
  n_observations <- length(series_values)

  # Forecast origin indices (t) that allow a full lag window and a future target
  forecast_origins <- lag_window:(n_observations - forecast_horizon)

  # Construct 2D matrix of lag windows
  X_mat <- t(sapply(forecast_origins, function(t_index) {
    series_values[(t_index - lag_window + 1):t_index]
  }))

  # Construct target vector at t + h
  y_vec <- sapply(forecast_origins, function(t_index) {
    series_values[t_index + forecast_horizon]
  })

  # Reshape to 3D array for LSTM: (samples, timesteps, features)
  X_arr <- array(data = as.numeric(X_mat),
                 dim = c(nrow(X_mat), lag_window, 1))

  list(X = X_arr, y = as.numeric(y_vec))
}

# make_pred_tbl()
# Run model predictions for a supervised split and align predictions to dates.
# Optionally inverse-transform y and y_hat back to the original log(SVR) scale.
make_pred_tbl <- function(model,
                          sup,
                          y_vec,
                          split_dates,
                          lag_window,
                          h,
                          which_split = c("val", "test"),
                          scaler_mu = NULL,
                          scaler_sd = NULL) {
  which_split <- match.arg(which_split)

  # Predict and compute residuals (on the scaled modeling scale)
  y_hat <- as.numeric(model %>% predict(sup$X))
  y_vec <- as.numeric(y_vec)
  resid <- y_vec - y_hat

  # Align prediction targets to the correct monthly dates
  n_split <- length(split_dates)
  target_idx <- (lag_window:(n_split - h)) + h
  dates <- split_dates[target_idx]

  out <- tibble(
    date = dates,
    y_scaled = y_vec,
    y_hat_scaled = y_hat,
    resid_scaled = resid,
    lag_window = lag_window,
    horizon = h,
    split = which_split
  )

  # If scaler parameters are supplied, invert y and y_hat back to log(SVR)
  if (!is.null(scaler_mu) && !is.null(scaler_sd)) {
    out <- out %>%
      mutate(
        y_raw = y_scaled * scaler_sd + scaler_mu,
        y_hat_raw = y_hat_scaled * scaler_sd + scaler_mu,
        resid_raw = y_raw - y_hat_raw
      )
  }

  return(out)
}

# Keras-side reproducibility (separate from set.seed)
set_random_seed(599)

# Lag windows to evaluate (number of months used as input timesteps)
lag_grid <- c(24, 18, 15, 12, 9, 6, 3)

# Collectors:
#   - results_lstm_list : per-run metric rows (one row per lag_window × h)
#   - preds_lstm_list   : per-run prediction tables for test split
results_lstm_list <- list()
preds_lstm_list   <- list()

# Forecast horizons (steps ahead)
horizons <- c(1, 3)

# Counter for list indexing across the full grid
i <- 0

# Training controls
patience <- 20
epoch    <- 300

# OUTER LOOP: iterate lag window sizes
for (lag_window in lag_grid) {
  # INNER LOOP: iterate forecast horizons
  for (h in horizons) {
    i <- i + 1

    # ---------------------------------------------------------------
    # Build supervised train/test sets for this (lag_window, h)
    #   - X is a 3D array: (samples, lag_window, 1)
    #   - y is the horizon target vector
    # ---------------------------------------------------------------
    sup_train <- make_supervised(train_df$y_scaled, lag_window, h)
    sup_test  <- make_supervised(test_df$y_scaled, lag_window, h)

    # Keras expects y as a 2D array for this setup: (samples, 1)
    y_train <- matrix(sup_train$y, ncol = 1)
    y_test  <- matrix(sup_test$y, ncol = 1)

    # Reset graph/session to avoid cross-run state bleed
    keras3::clear_session()
    set_random_seed(599 + lag_window * 10 + h)

    # Define a simple LSTM:
    #   input: (timesteps = lag_window, features = 1)
    #   recurrent: 16-unit LSTM layer
    #   output: 1-unit linear dense layer (regression)
    model <- keras_model_sequential() %>%
      layer_lstm(units = 16, input_shape = c(lag_window, 1)) %>%
      layer_dense(units = 1)

    # Compile with MSE loss and MAE metric (NN-style evaluation)
    model %>%
      compile(optimizer = "adam",
              loss = "mse",
              metrics = list("mae"))

    # Early stopping: choose the epoch that minimizes internal validation loss
    cb_es <- callback_early_stopping(
      monitor = "val_loss",
      patience = patience,
      restore_best_weights = TRUE
    )

    # Fit the model on TRAIN, using the last 20% of training samples
    # as the internal validation split for early stopping
    history <- model %>%
      fit(
        x = sup_train$X,
        y = y_train,
        validation_split = 0.20,
        epochs = epoch,
        batch_size = 32,
        shuffle = FALSE,
        callbacks = list(cb_es),
        verbose = 1
      )

    # Identify the epoch with minimum validation loss (for reporting)
    best_epoch <- which.min(history$metrics$val_loss)

    # Evaluate test performance on the scaled modeling scale
    test_metrics <- model %>% evaluate(sup_test$X, y_test, verbose = 0)


    # ---------------------------------------------------------------
    # Store prediction tables (scaled + inverse-transformed columns)
    # ---------------------------------------------------------------

    preds_lstm_list[[i]] <-
      make_pred_tbl(
        model,
        sup_test,
        y_test,
        test_df$date,
        lag_window,
        h,
        "test",
        scaler_mu = scaler_mu,
        scaler_sd = scaler_sd
      ) %>%
      select(-split)

    # ---------------------------------------------------------------
    # Raw-scale metrics: compute errors on inverse-transformed log(SVR)
    # ---------------------------------------------------------------

    test_pred_tbl <- preds_lstm_list[[i]]

    test_mse_raw  <- mean((test_pred_tbl$y_raw - test_pred_tbl$y_hat_raw)^2, na.rm = TRUE)
    test_rmse_raw <- sqrt(test_mse_raw)
    test_mae_raw  <- mean(abs(test_pred_tbl$y_raw - test_pred_tbl$y_hat_raw),
                          na.rm = TRUE)


    # ---------------------------------------------------------------
    # Store one metrics row for this (lag_window, h)
    #   - test_* are on the SCALED modeling scale (from evaluate())
    #   - *_raw are on the ORIGINAL log(SVR) scale (inverse-transformed)
    # ---------------------------------------------------------------
    results_lstm_list[[i]] <- tibble(
      lag_window = lag_window,
      horizon    = h,
      best_epoch = best_epoch,

      test_mse   = as.numeric(test_metrics[[1]]),
      test_rmse  = sqrt(as.numeric(test_metrics[[1]])),
      test_mae   = as.numeric(test_metrics[[2]]),

      test_mse_raw   = test_mse_raw,
      test_rmse_raw  = test_rmse_raw,
      test_mae_raw   = test_mae_raw
    )
  }
}



# Bind per-run lists into long tables
results_lstm <- bind_rows(results_lstm_list)
preds_lstm   <- bind_rows(preds_lstm_list)

# Rank models by horizon then test MAE
metrics_lstm_result <- results_lstm %>%
  arrange(horizon, test_mae_raw)

# Select the best LSTM configuration for each forecast horizon
selected_lstm_models <- metrics_lstm_result %>%
  group_by(horizon) %>%
  slice_min(
    order_by = test_mae_raw,
    n = 1,
    with_ties = FALSE
  ) %>%
  ungroup()

# Select predictions generated by the winning configuration for each horizon
selected_lstm_predictions <- preds_lstm %>%
  semi_join(
    selected_lstm_models %>%
      select(lag_window, horizon),
    by = c("lag_window", "horizon")
  ) %>%
  arrange(horizon, date) %>%
  transmute(
    date = as.character(date),
    horizon,
    lag_window,
    actual_log_svr = y_raw,
    predicted_log_svr = y_hat_raw,
    residual_log_svr = resid_raw
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

# Build standardized LSTM output artifact
lstm_output_artifact <- list(
  schema_version = "1.0",

  metadata = list(
    run_id = run_id,
    model_name = "SVR-LSTM",
    model_family = "neural_network",
    target = "log_svr",
    selection_metric = "test_mae_raw",
    selection_direction = "minimize",
    generated_at_utc = generated_at_utc,
    data_start_date = as.character(min(df_all$date)),
    latest_model_month = as.character(model_window$latest_model_month),
    latest_model_month_end = as.character(model_window$latest_model_month_end),
    train_start_date = as.character(min(train_df$date)),
    train_end_date = as.character(max(train_df$date)),
    test_start_date = as.character(min(test_df$date)),
    test_end_date = as.character(max(test_df$date)),
    observation_count = nrow(df_all),
    test_observation_count = n_test
  ),

  metrics = metrics_lstm_result,

  selected_models = selected_lstm_models,

  predictions = selected_lstm_predictions
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
  paste0("lstm_", run_id, ".json")
)

# Write standardized LSTM output artifact
jsonlite::write_json(
  lstm_output_artifact,
  path = artifact_path,
  pretty = TRUE,
  auto_unbox = TRUE,
  dataframe = "rows",
  na = "null",
  null = "null",
  digits = NA
)

# CSV Export
write_csv(metrics_lstm_result, "LSTM Metrics SELECTED FINAL.csv")

# Print metrics table
metrics_lstm_result
