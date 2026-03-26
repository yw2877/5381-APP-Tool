get_price_history <- function(symbol, lookback = DEFAULT_LOOKBACK) {
  asset <- asset_row(symbol)
  lookback <- as.integer(lookback %||% DEFAULT_LOOKBACK)
  lookback <- max(30L, lookback)

  set.seed(symbol_seed(symbol))

  dates <- seq(Sys.Date() - lookback + 1L, Sys.Date(), by = "day")
  n <- length(dates)
  drift <- if (asset$asset_class[[1]] == "Crypto") 0.0008 else 0.0004
  noise <- stats::rnorm(n, mean = drift, sd = asset$vol_scale[[1]])

  shock_index <- max(10L, n - 7L):n
  shock_path <- seq(-0.45, 0.75, length.out = length(shock_index)) * asset$vol_scale[[1]]
  noise[shock_index] <- noise[shock_index] + shock_path

  close <- asset$base_price[[1]] * cumprod(pmax(1 + noise, 0.55))
  ret <- c(NA_real_, diff(log(close)))

  tibble::tibble(
    date = dates,
    close = close,
    ret = ret
  )
}

rolling_volatility <- function(price_df, window = 20L) {
  rets <- stats::na.omit(price_df$ret)
  if (length(rets) < 2) {
    return(NA_real_)
  }

  stats::sd(utils::tail(rets, window)) * sqrt(252)
}

max_drawdown <- function(price_df) {
  if (!nrow(price_df)) {
    return(NA_real_)
  }

  running_max <- cummax(price_df$close)
  drawdown <- price_df$close / running_max - 1
  min(drawdown, na.rm = TRUE)
}

historical_var_es <- function(price_df, window = 60L, conf = 0.95) {
  rets <- utils::tail(stats::na.omit(price_df$ret), window)
  if (length(rets) < 10) {
    return(list(
      var_1d = NA_real_,
      es_1d = NA_real_,
      var_5d = NA_real_,
      es_5d = NA_real_
    ))
  }

  losses <- -rets
  var_1d <- as.numeric(stats::quantile(losses, probs = conf, na.rm = TRUE))
  es_1d <- mean(losses[losses >= var_1d], na.rm = TRUE)

  scale_5d <- sqrt(5)
  list(
    var_1d = var_1d,
    es_1d = es_1d,
    var_5d = var_1d * scale_5d,
    es_5d = es_1d * scale_5d
  )
}

correlation_jump <- function(symbol, benchmark_symbol = "SPY", lookback_short = 20L, lookback_long = 60L) {
  lhs <- get_price_history(symbol, lookback = max(lookback_short, lookback_long) + 5L)
  rhs <- get_price_history(benchmark_symbol, lookback = max(lookback_short, lookback_long) + 5L)

  merged <- merge(lhs[c("date", "ret")], rhs[c("date", "ret")], by = "date", suffixes = c("_lhs", "_rhs"))
  merged <- merged[stats::complete.cases(merged), , drop = FALSE]

  if (nrow(merged) < lookback_long) {
    return(NA_real_)
  }

  short_corr <- stats::cor(
    utils::tail(merged$ret_lhs, lookback_short),
    utils::tail(merged$ret_rhs, lookback_short)
  )
  long_corr <- stats::cor(
    utils::tail(merged$ret_lhs, lookback_long),
    utils::tail(merged$ret_rhs, lookback_long)
  )

  short_corr - long_corr
}

regime_score <- function(price_df) {
  vol_score <- clip01(rolling_volatility(price_df) / 0.75)
  dd_score <- clip01(abs(max_drawdown(price_df)) / 0.25)

  tail_window <- utils::tail(price_df$close, 20)
  momentum <- if (length(tail_window) >= 2) {
    utils::tail(tail_window, 1) / tail_window[[1]] - 1
  } else {
    0
  }
  momentum_score <- clip01(abs(min(momentum, 0)) / 0.12)

  clip01(0.45 * vol_score + 0.35 * dd_score + 0.20 * momentum_score)
}

compute_risk_metrics <- function(symbol, lookback = DEFAULT_LOOKBACK) {
  prices <- get_price_history(symbol, lookback = lookback)
  tails <- historical_var_es(prices)

  vol20 <- rolling_volatility(prices, window = 20L)
  drawdown <- max_drawdown(prices)
  corr_jump <- correlation_jump(symbol)
  regime <- regime_score(prices)

  driver_scores <- c(
    volatility = clip01(vol20 / 0.80),
    drawdown = clip01(abs(drawdown) / 0.25),
    correlation = clip01(abs(corr_jump) / 0.35)
  )

  risk_level <- risk_level_from_score(
    0.55 * regime + 0.25 * clip01(tails$es_1d / 0.08) + 0.20 * clip01(abs(drawdown) / 0.25)
  )

  list(
    symbol = safe_chr(symbol, default = "SPY"),
    latest_price = utils::tail(prices$close, 1),
    rolling_vol_20d = vol20,
    max_drawdown = drawdown,
    var_1d = tails$var_1d,
    es_1d = tails$es_1d,
    var_5d = tails$var_5d,
    es_5d = tails$es_5d,
    correlation_jump = corr_jump,
    regime_score = regime,
    primary_driver = names(driver_scores)[which.max(driver_scores)],
    risk_level = risk_level
  )
}
