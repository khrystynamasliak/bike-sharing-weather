#!/usr/bin/env Rscript
# ============================================================================
# 03_fetch_meteoswiss.R
#
# Download hourly weather from MeteoSwiss - the project's second, independent
# data source.
#
# MeteoSwiss publishes ground-based measurements from its SwissMetNet automatic
# weather station network as Open Government Data, distributed through
# swisstopo's STAC API. Different publisher, different instrument, different
# licence to the PubliBike feed - but it joins cleanly on the hour because both
# sources timestamp in UTC.
#
# Usage:
#   Rscript 03_fetch_meteoswiss.R --stations derived/stations.csv --list
#   Rscript 03_fetch_meteoswiss.R --stations derived/stations.csv --out derived
#   Rscript 03_fetch_meteoswiss.R --station-abbr BER --out derived
#
# Source data quirks (from opendatadocs.meteoswiss.ch):
#   * CSVs are encoded Windows-1252, not UTF-8
#   * Dates are formatted dd.mm.yyyy HH:MM
#   * All timestamps are UTC
#   * Hourly values are BACKWARD-looking: 16:00 covers 15:10 to 16:00
#   * Download the hourly aggregate rather than aggregating 10-minute data
#     yourself - corrections are applied at the aggregated level
#
# Dependencies: jsonlite
# ============================================================================

suppressPackageStartupMessages({
  if (!requireNamespace("jsonlite", quietly = TRUE)) {
    stop("This script needs jsonlite. Run:  install.packages('jsonlite')")
  }
  library(jsonlite)
})

STAC_ROOT  <- "https://data.geo.admin.ch/api/stac/v1"
COLLECTION <- "ch.meteoschweiz.ogd-smn"

# SwissMetNet parameter codes -> readable names. Unlisted codes are kept under
# their original name rather than dropped.
PARAM_NAMES <- c(
  tre200h0 = "temp_c",          # air temperature 2m, hourly mean
  rre150h0 = "precip_mm",       # precipitation, hourly total
  fkl010h0 = "wind_speed_ms",   # wind speed, hourly mean
  fkl010h1 = "wind_gust_ms",    # gust peak
  ure200h0 = "humidity_pct",    # relative humidity 2m
  gre000h0 = "radiation_wm2",   # global radiation
  sre000h0 = "sunshine_min",    # sunshine duration, minutes in the hour
  prestah0 = "pressure_hpa"     # pressure at station level
)

parse_args <- function(args) {
  opts <- list(stations = NULL, abbr = NULL, out = "derived",
               list_only = FALSE, top = 8, historical = FALSE)
  i <- 1
  while (i <= length(args)) {
    a <- args[[i]]
    if (a == "--stations")        { i <- i + 1; opts$stations <- args[[i]] }
    else if (a == "--station-abbr") { i <- i + 1; opts$abbr <- args[[i]] }
    else if (a == "--out")        { i <- i + 1; opts$out <- args[[i]] }
    else if (a == "--top")        { i <- i + 1; opts$top <- as.integer(args[[i]]) }
    else if (a == "--list")       opts$list_only <- TRUE
    else if (a == "--historical") opts$historical <- TRUE
    else stop("Unknown argument: ", a)
    i <- i + 1
  }
  opts
}

haversine_km <- function(lat1, lon1, lat2, lon2) {
  r <- 6371
  p1 <- lat1 * pi / 180; p2 <- lat2 * pi / 180
  dp <- (lat2 - lat1) * pi / 180
  dl <- (lon2 - lon1) * pi / 180
  a <- sin(dp / 2)^2 + cos(p1) * cos(p2) * sin(dl / 2)^2
  2 * r * asin(pmin(1, sqrt(a)))
}

# Locate a column by substring, since MeteoSwiss column names may change.
find_col <- function(df, ...) {
  needles <- tolower(c(...))
  for (nm in names(df)) {
    low <- tolower(nm)
    if (all(vapply(needles, function(n) grepl(n, low, fixed = TRUE), logical(1)))) {
      return(nm)
    }
  }
  NULL
}

# Read a MeteoSwiss CSV, sniffing the separator (they use ';').
read_ms_csv <- function(url) {
  tmp <- tempfile(fileext = ".csv")
  on.exit(unlink(tmp), add = TRUE)
  utils::download.file(url, tmp, quiet = TRUE, mode = "wb")
  df <- utils::read.csv2(tmp, fileEncoding = "latin1", stringsAsFactors = FALSE,
                         check.names = TRUE)
  if (ncol(df) == 1) {
    df <- utils::read.csv(tmp, fileEncoding = "latin1", stringsAsFactors = FALSE,
                          check.names = TRUE)
  }
  df
}

fetch_station_metadata <- function() {
  meta_url <- NULL

  coll <- tryCatch(jsonlite::fromJSON(paste0(STAC_ROOT, "/collections/", COLLECTION)),
                   error = function(e) NULL)
  if (!is.null(coll) && !is.null(coll$assets)) {
    hrefs <- unlist(lapply(coll$assets, function(a) a$href))
    hit <- grep("meta_stations", hrefs, value = TRUE)
    if (length(hit)) meta_url <- hit[[1]]
  }

  if (is.null(meta_url)) {
    items <- tryCatch(
      jsonlite::fromJSON(paste0(STAC_ROOT, "/collections/", COLLECTION,
                                "/items?limit=100"), simplifyVector = FALSE),
      error = function(e) NULL)
    if (!is.null(items)) {
      for (it in items$features) {
        hrefs <- unlist(lapply(it$assets, function(a) a$href))
        hit <- grep("meta_stations", hrefs, value = TRUE)
        if (length(hit)) { meta_url <- hit[[1]]; break }
      }
    }
  }

  if (is.null(meta_url)) {
    stop("Could not locate ogd-smn_meta_stations.csv in the STAC collection. ",
         "See https://opendatadocs.meteoswiss.ch/general/download for the ",
         "current structure.")
  }

  cat("Station metadata:", meta_url, "\n")
  df <- read_ms_csv(meta_url)
  cat(sprintf("Loaded %d MeteoSwiss stations\n", nrow(df)))
  df
}

normalise_stations <- function(df) {
  lat_col  <- find_col(df, "lat");  if (is.null(lat_col))  lat_col  <- find_col(df, "wgs84", "north")
  lon_col  <- find_col(df, "lon");  if (is.null(lon_col))  lon_col  <- find_col(df, "wgs84", "east")
  abbr_col <- find_col(df, "abbr"); if (is.null(abbr_col)) abbr_col <- find_col(df, "station", "id")
  name_col <- find_col(df, "station", "name"); if (is.null(name_col)) name_col <- abbr_col

  missing <- c(if (is.null(lat_col)) "latitude",
               if (is.null(lon_col)) "longitude",
               if (is.null(abbr_col)) "abbreviation")
  if (length(missing)) {
    stop("Could not identify ", paste(missing, collapse = ", "),
         " in the station metadata. Columns: ", paste(names(df), collapse = ", "))
  }

  out <- data.frame(
    weather_station_abbr = trimws(as.character(df[[abbr_col]])),
    weather_station_name = as.character(df[[name_col]]),
    weather_lat = suppressWarnings(as.numeric(df[[lat_col]])),
    weather_lon = suppressWarnings(as.numeric(df[[lon_col]])),
    stringsAsFactors = FALSE
  )
  out[!is.na(out$weather_lat) & !is.na(out$weather_lon), ]
}

find_hourly_assets <- function(abbr) {
  url <- paste0(STAC_ROOT, "/collections/", COLLECTION, "/items/", tolower(abbr))
  item <- tryCatch(jsonlite::fromJSON(url, simplifyVector = FALSE),
                   error = function(e) stop("No STAC item for station '", abbr,
                                            "'. Check the abbreviation."))
  hrefs <- unlist(lapply(item$assets, function(a) a$href))
  hourly <- grep("_h_.*\\.csv$", tolower(hrefs))
  if (length(hourly) == 0) {
    stop("No hourly (_h_) CSV for ", abbr, ". Assets: ",
         paste(names(item$assets), collapse = ", "))
  }
  hrefs <- hrefs[hourly]
  # prefer 'now' then 'recent' - those cover the period your bike data spans
  prio <- ifelse(grepl("_now", tolower(hrefs)), 0L,
                 ifelse(grepl("_recent", tolower(hrefs)), 1L, 2L))
  hrefs[order(prio)]
}

# Parse the MeteoSwiss timestamp column.
#
# The documented format is dd.mm.yyyy HH:MM, but OGD exports have used several
# over time. Try each explicitly, keep whichever parses the most rows, and then
# VERIFY that time-of-day actually varies - a format string that consumes only
# the date silently collapses every hour of a day onto midnight, which looks
# fine until the join returns nothing.
TIME_FORMATS <- c(
  "%d.%m.%Y %H:%M",      # documented MeteoSwiss format
  "%Y-%m-%d %H:%M:%S",
  "%Y-%m-%dT%H:%M:%S",
  "%Y-%m-%d %H:%M",
  "%Y%m%d%H%M",          # compact
  "%Y%m%d%H",
  "%d.%m.%Y %H:%M:%S",
  "%d/%m/%Y %H:%M",
  # Date-only formats last: they parse, but score low because they carry no
  # hour, so they are only chosen when nothing better matches.
  "%d.%m.%Y",
  "%Y-%m-%d"
)

parse_timestamps <- function(x) {
  x <- trimws(as.character(x))
  cat("  timestamp samples: ", paste(utils::head(x, 3), collapse = " | "), "\n", sep = "")

  best <- NULL; best_fmt <- NA; best_score <- -1
  for (fmt in TIME_FORMATS) {
    ts <- suppressWarnings(as.POSIXct(x, format = fmt, tz = "UTC"))
    ok <- mean(!is.na(ts))
    if (ok < 0.5) next
    # A format that drops the time gives one distinct value per day.
    hours_seen <- length(unique(format(ts[!is.na(ts)], "%H")))
    score <- ok + (hours_seen > 1) * 10        # strongly prefer formats that keep the hour
    if (score > best_score) { best <- ts; best_fmt <- fmt; best_score <- score }
  }

  if (is.null(best)) {                          # last resort: let R guess
    best <- tryCatch(suppressWarnings(as.POSIXct(x, tz = "UTC")),
                     error = function(e) rep(as.POSIXct(NA, tz = "UTC"), length(x)))
    best_fmt <- "auto"
  }
  if (all(is.na(best))) {
    stop("Could not parse any timestamp. Samples: ",
         paste(utils::head(x, 3), collapse = " | "))
  }

  hours_seen <- length(unique(format(best[!is.na(best)], "%H")))
  cat("  parsed with format: ", best_fmt,
      "  (", round(100 * mean(!is.na(best))), "% of rows, ",
      hours_seen, " distinct hours-of-day)\n", sep = "")

  if (hours_seen <= 1) {
    warning("Timestamps carry no time-of-day - every reading collapsed to one ",
            "hour per day. The join to bike data will fail. Check the raw ",
            "timestamp samples printed above.", call. = FALSE)
  }
  best
}

tidy_weather <- function(df) {
  time_col <- find_col(df, "reference_timestamp")
  if (is.null(time_col)) time_col <- find_col(df, "time")
  if (is.null(time_col)) time_col <- find_col(df, "date")
  if (is.null(time_col)) stop("No timestamp column. Columns: ",
                              paste(names(df), collapse = ", "))
  cat("  timestamp column:  ", time_col, "\n", sep = "")

  ts <- parse_timestamps(df[[time_col]])

  out <- data.frame(hour = ts, stringsAsFactors = FALSE)
  station_col <- find_col(df, "station", "abbr")
  if (!is.null(station_col)) out$weather_station_abbr <- df[[station_col]]

  renamed <- 0
  for (nm in names(df)) {
    key <- tolower(trimws(nm))
    if (identical(nm, time_col) || identical(nm, station_col)) next
    target <- if (key %in% names(PARAM_NAMES)) {
      renamed <- renamed + 1; PARAM_NAMES[[key]]
    } else key
    out[[target]] <- suppressWarnings(as.numeric(df[[nm]]))
  }

  out <- out[!is.na(out$hour), ]
  out <- out[order(out$hour), ]
  # Snap to the exact hour so the join key matches the bike side.
  out$hour <- as.POSIXct(round(as.numeric(out$hour) / 3600) * 3600,
                         origin = "1970-01-01", tz = "UTC")
  out <- out[!duplicated(out$hour), ]

  cat(sprintf("  %s hourly rows (%s to %s), %d known parameters recognised\n",
              format(nrow(out), big.mark = ","), min(out$hour), max(out$hour), renamed))
  out
}

main <- function() {
  opts <- parse_args(commandArgs(trailingOnly = TRUE))
  if (is.null(opts$stations) && is.null(opts$abbr)) {
    stop("Give --stations (to pick automatically) or --station-abbr.")
  }
  dir.create(opts$out, recursive = TRUE, showWarnings = FALSE)

  weather <- normalise_stations(fetch_station_metadata())
  write.csv(weather, file.path(opts$out, "weather_stations.csv"), row.names = FALSE)

  abbr <- opts$abbr
  if (!is.null(opts$stations)) {
    bikes <- read.csv(opts$stations, stringsAsFactors = FALSE)
    clat <- mean(as.numeric(bikes$lat), na.rm = TRUE)
    clon <- mean(as.numeric(bikes$lon), na.rm = TRUE)
    cat(sprintf("\nBike network centroid: %.4f, %.4f\n", clat, clon))

    weather$distance_km <- haversine_km(clat, clon, weather$weather_lat, weather$weather_lon)
    ranked <- weather[order(weather$distance_km), ]

    cat("\nNearest MeteoSwiss stations:\n")
    for (i in seq_len(min(opts$top, nrow(ranked)))) {
      cat(sprintf("  %-6s %-34s %6.1f km\n", ranked$weather_station_abbr[i],
                  substr(ranked$weather_station_name[i], 1, 32),
                  ranked$distance_km[i]))
    }
    if (opts$list_only) return(invisible(NULL))
    if (is.null(abbr)) {
      abbr <- ranked$weather_station_abbr[1]
      cat("\nUsing nearest station:", abbr, "\n")
    }
  }

  cat("\nFetching hourly data for", abbr, "\n")
  hrefs <- find_hourly_assets(abbr)
  parts <- list()
  for (h in hrefs) {
    nm <- basename(h)
    if (!opts$historical && grepl("historical", tolower(nm))) next
    cat("  downloading", nm, "\n")
    parts[[length(parts) + 1]] <- read_ms_csv(h)
  }
  if (length(parts) == 0) stop("Nothing downloaded.")

  common <- Reduce(intersect, lapply(parts, names))
  raw <- do.call(rbind, lapply(parts, function(p) p[, common, drop = FALSE]))
  tidy <- tidy_weather(raw)

  path <- file.path(opts$out, "weather_hourly.csv")
  write.csv(tidy, path, row.names = FALSE)
  cat("\nWrote", path, "\n")

  for (v in c("temp_c", "precip_mm", "wind_speed_ms")) {
    if (v %in% names(tidy) && any(!is.na(tidy[[v]]))) {
      cat(sprintf("  %-16s min %7.1f  mean %7.1f  max %7.1f\n", v,
                  min(tidy[[v]], na.rm = TRUE), mean(tidy[[v]], na.rm = TRUE),
                  max(tidy[[v]], na.rm = TRUE)))
    }
  }
}

main()
