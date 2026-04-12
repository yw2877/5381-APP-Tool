# Resolve app root so .env and APP_ROOT stay aligned when getwd() is not the repo.
find_app_root <- function() {
  explicit <- Sys.getenv("APPV2_ROOT", unset = "")
  if (nzchar(trimws(explicit))) {
    return(normalizePath(trimws(explicit), winslash = "/", mustWork = TRUE))
  }

  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", args, value = TRUE)
  if (length(file_arg)) {
    sc <- sub("^--file=", "", file_arg[[1]])
    if (nzchar(sc) && !startsWith(sc, "-") && !identical(sc, "stdin")) {
      rp <- tryCatch(
        normalizePath(sc, winslash = "/", mustWork = TRUE),
        error = function(e) ""
      )
      if (nzchar(rp) && identical(tolower(basename(rp)), "app.r")) {
        return(dirname(rp))
      }
    }
  }

  d <- normalizePath(getwd(), winslash = "/", mustWork = FALSE)
  for (step in seq_len(40L)) {
    if (file.exists(file.path(d, "app.R"))) {
      return(d)
    }
    sub_app <- file.path(d, "5381-APP-Tool", "app.R")
    if (file.exists(sub_app)) {
      return(dirname(sub_app))
    }
    p <- dirname(d)
    if (identical(p, d)) {
      break
    }
    d <- p
  }

  normalizePath(getwd(), winslash = "/", mustWork = FALSE)
}
