# ============================================================================
# Agent output schemas — declarative validation rules for LLM responses.
#
# Each schema is a named list. Keys describe the expected JSON keys returned
# by the agent. Values describe the expected type and (optional) constraints:
#   - type: "character" | "numeric" | "logical" | "list"
#   - enum: allowed values (for character)
#   - min, max: numeric bounds
#   - min_chars, max_chars: string length bounds
#   - min_len, max_len: list length bounds
#   - elem_type: type of each list element
#   - keys: required sub-keys (for nested object/list)
#   - nullable: TRUE if NA / NULL is acceptable
#
# `validate_against_schema(obj, schema)` returns
#   list(ok = TRUE/FALSE, errors = c(...))
# Used by R/llm.R to gate parsed responses; failure triggers schema-repair retry.
# ============================================================================

TRIAGE_SCHEMA <- list(
  signal_type = list(
    type = "character",
    enum = c("trend_break", "volatility_spike", "momentum_reversal",
             "liquidity_stress", "watchlist_signal")
  ),
  severity_hint = list(
    type = "character",
    enum = c("low", "medium", "high")
  ),
  rationale = list(
    type = "character",
    min_chars = 30, max_chars = 600
  ),
  suggested_focus = list(
    type = "list",
    min_len = 2, max_len = 5,
    elem_type = "character"
  )
)

MEMO_SCHEMA <- list(
  headline = list(
    type = "character",
    min_chars = 10, max_chars = 120
  ),
  memo = list(
    type = "character",
    min_chars = 100, max_chars = 1500
  ),
  recommended_action = list(
    type = "character",
    min_chars = 15, max_chars = 300
  )
)

CRITIC_SCHEMA <- list(
  quality_score = list(
    type = "numeric",
    min = 0, max = 1
  ),
  passes = list(
    type = "logical"
  ),
  dimension_scores = list(
    type = "list",
    keys = c("clarity", "completeness", "actionability",
             "factual_alignment", "tone")
  ),
  issues = list(
    type = "list",
    min_len = 0, max_len = 8,
    elem_type = "character"
  ),
  improvement_directives = list(
    type = "character",
    min_chars = 0, max_chars = 800
  )
)

# ----- Risk metrics range guardrails -----
# Used by R/quality.R to clip & flag implausible Yahoo Finance values.
# nullable = TRUE because compute_risk_metrics() can return NA on data issues.
RISK_METRICS_RANGES <- list(
  rolling_vol_20d  = list(min = 0,    max = 5,    nullable = TRUE),
  max_drawdown     = list(min = -1,   max = 0,    nullable = TRUE),
  var_1d           = list(min = 0,    max = 1,    nullable = TRUE),
  es_1d            = list(min = 0,    max = 1,    nullable = TRUE),
  var_5d           = list(min = 0,    max = 1,    nullable = TRUE),
  es_5d            = list(min = 0,    max = 1,    nullable = TRUE),
  correlation_jump = list(min = -2,   max = 2,    nullable = TRUE),
  regime_score     = list(min = 0,    max = 1,    nullable = TRUE),
  alert_gap        = list(min = -10,  max = 10,   nullable = TRUE)
)

# ============================================================================
# Validator
# ============================================================================

validate_against_schema <- function(obj, schema) {
  errors <- character(0)

  if (is.null(obj) || !is.list(obj)) {
    return(list(ok = FALSE, errors = "Response is not a JSON object/list."))
  }

  for (key in names(schema)) {
    rule <- schema[[key]]
    val  <- obj[[key]]

    # Missing key
    if (is.null(val)) {
      if (isTRUE(rule$nullable)) next
      errors <- c(errors, sprintf("Missing required key: '%s'", key))
      next
    }

    # Type check
    if (!is.null(rule$type)) {
      type_ok <- switch(rule$type,
        "character" = is.character(val) || (is.list(val) && length(val) == 1 && is.character(val[[1]])),
        "numeric"   = is.numeric(val) || (is.list(val) && length(val) == 1 && is.numeric(val[[1]])),
        "logical"   = is.logical(val) || (is.list(val) && length(val) == 1 && is.logical(val[[1]])),
        "list"      = is.list(val),
        TRUE
      )
      if (!type_ok) {
        errors <- c(errors,
          sprintf("Key '%s' has wrong type (expected %s).", key, rule$type))
        next
      }
    }

    # Coerce single-element list to scalar for downstream checks
    raw_val <- val
    if (is.list(val) && length(val) == 1 &&
        rule$type %in% c("character", "numeric", "logical")) {
      val <- val[[1]]
    }

    # Enum check (character)
    if (!is.null(rule$enum) && is.character(val)) {
      if (!val %in% rule$enum) {
        errors <- c(errors,
          sprintf("Key '%s' value '%s' not in allowed set: %s",
                  key, val, paste(rule$enum, collapse = ", ")))
      }
    }

    # String length bounds
    if (is.character(val)) {
      n <- nchar(val)
      if (!is.null(rule$min_chars) && n < rule$min_chars) {
        errors <- c(errors,
          sprintf("Key '%s' too short (got %d, min %d chars).",
                  key, n, rule$min_chars))
      }
      if (!is.null(rule$max_chars) && n > rule$max_chars) {
        errors <- c(errors,
          sprintf("Key '%s' too long (got %d, max %d chars).",
                  key, n, rule$max_chars))
      }
    }

    # Numeric bounds
    if (is.numeric(val)) {
      if (!is.null(rule$min) && val < rule$min) {
        errors <- c(errors,
          sprintf("Key '%s' below min (got %s, min %s).",
                  key, val, rule$min))
      }
      if (!is.null(rule$max) && val > rule$max) {
        errors <- c(errors,
          sprintf("Key '%s' above max (got %s, max %s).",
                  key, val, rule$max))
      }
    }

    # List length + element type
    if (is.list(raw_val) && rule$type == "list") {
      if (!is.null(rule$min_len) && length(raw_val) < rule$min_len) {
        errors <- c(errors,
          sprintf("Key '%s' list too short (got %d, min %d).",
                  key, length(raw_val), rule$min_len))
      }
      if (!is.null(rule$max_len) && length(raw_val) > rule$max_len) {
        errors <- c(errors,
          sprintf("Key '%s' list too long (got %d, max %d).",
                  key, length(raw_val), rule$max_len))
      }
      if (!is.null(rule$elem_type)) {
        bad <- vapply(raw_val, function(e) {
          switch(rule$elem_type,
            "character" = !is.character(e) && !(is.list(e) && length(e) == 1 && is.character(e[[1]])),
            "numeric"   = !is.numeric(e),
            FALSE)
        }, logical(1))
        if (any(bad)) {
          errors <- c(errors,
            sprintf("Key '%s' has %d elements of wrong type (expected %s).",
                    key, sum(bad), rule$elem_type))
        }
      }
      if (!is.null(rule$keys)) {
        missing_keys <- setdiff(rule$keys, names(raw_val))
        if (length(missing_keys)) {
          errors <- c(errors,
            sprintf("Key '%s' missing sub-keys: %s",
                    key, paste(missing_keys, collapse = ", ")))
        }
      }
    }
  }

  list(ok = length(errors) == 0, errors = errors)
}

# ============================================================================
# Schema description for prompt-repair
# Renders a schema as a compact human-readable spec that we can inject back
# into a follow-up prompt when validation fails.
# ============================================================================

describe_schema <- function(schema) {
  lines <- vapply(names(schema), function(key) {
    rule <- schema[[key]]
    parts <- c(rule$type)
    if (!is.null(rule$enum))
      parts <- c(parts, sprintf("one of: %s", paste(rule$enum, collapse = "/")))
    if (!is.null(rule$min_chars) || !is.null(rule$max_chars))
      parts <- c(parts, sprintf("length %s-%s",
                                rule$min_chars %||% "any",
                                rule$max_chars %||% "any"))
    if (!is.null(rule$min) || !is.null(rule$max))
      parts <- c(parts, sprintf("range %s..%s",
                                rule$min %||% "-inf",
                                rule$max %||% "inf"))
    if (!is.null(rule$min_len) || !is.null(rule$max_len))
      parts <- c(parts, sprintf("array length %s-%s",
                                rule$min_len %||% 0,
                                rule$max_len %||% "any"))
    if (!is.null(rule$keys))
      parts <- c(parts, sprintf("with sub-keys: %s",
                                paste(rule$keys, collapse = ", ")))
    sprintf("  %s: %s", key, paste(parts, collapse = ", "))
  }, character(1))
  paste(c("{", lines, "}"), collapse = "\n")
}
