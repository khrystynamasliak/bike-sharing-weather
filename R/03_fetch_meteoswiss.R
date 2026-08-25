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

# Station names carry umlauts and accents (Mühleberg, Charrière). If R is
# running under a non-UTF-8 locale - a bare shell gives you "C" - write.csv
# cannot represent them and silently writes the literal text "M<U+00FC>hleberg"
# into the data instead. Ask for a UTF-8 locale before anything is written.
local({
  if (isTRUE(l10n_info()[["UTF-8"]])) return(invisible(NULL))
  for (loc in c("C.UTF-8", "en_US.UTF-8", "de_CH.UTF-8", "UTF-8")) {
    if (nzchar(suppressWarnings(Sys.setlocale("LC_CTYPE", loc)))) break
  }
  if (!isTRUE(l10n_info()[["UTF-8"]])) {
    warning("No UTF-8 locale available; accented station names may be mangled ",
            "in the output CSVs.", call. = FALSE)
  }
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
#
# The files are Windows-1252, and the obvious approach - read.csv2(fileEncoding
# = "latin1") - is locale-dependent and fails BADLY when it fails. Under a
# non-UTF-8 locale, R tries to re-encode into the native charset, cannot
# represent "météorologiques", and stops reading at that line with only a
# warning. The station metadata then comes back with ONE row instead of 158,
# and the script cheerfully picks the "nearest" weather station from a list of
# one. It works on a UTF-8 CI runner and silently mangles the analysis anywhere
# else, which is the worst combination.
#
# Reading the bytes and converting explicitly with iconv gives the same result
# in every locale.
read_ms_csv <- function(url) {
  tmp <- tempfile(fileext = ".csv")
  on.exit(unlink(tmp), add = TRUE)
  utils::download.file(url, tmp, quiet = TRUE, mode = "wb")

  lines <- readLines(tmp, warn = FALSE)
  lines <- iconv(lines, from = "WINDOWS-1252", to = "UTF-8", sub = "?")
  lines <- lines[!is.na(lines)]
  if (length(lines) == 0) stop("Downloaded an empty file from ", url)

  df <- utils::read.csv2(text = lines, stringsAsFactors = FALSE, check.names = TRUE)
  if (ncol(df) == 1) {
    df <- utils::read.csv(text = lines, stringsAsFactors = FALSE, check.names = TRUE)
  }
  if (nrow(df) < length(lines) - 2) {
    warning("Read ", nrow(df), " rows from a ", length(lines),
            "-line file - parsing stopped early. Check ", basename(url),
            call. = FALSE)
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
  # SwissMetNet has ~160 automatic stations. A handful means the CSV was only
  # partly parsed, and "nearest station" would then be chosen from whatever
  # happened to survive - a wrong answer that looks like a right one.
  if (nrow(df) < 50) {
    stop("Only ", nrow(df), " weather stations parsed; expected around 160. ",
         "The metadata CSV was not read properly - do not trust a station ",
         "chosen from this list.")
  }
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

# Every column that could plausibly hold a timestamp, best candidates first.
candidate_time_cols <- function(df) {
  pats <- list(c("reference_timestamp"), c("timestamp"), c("datetime"),
               c("date", "time"), c("time"), c("date"))
  found <- character(0)
  for (p in pats) {
    hit <- find_col(df, p)
    if (!is.null(hit) && !(hit %in% found)) found <- c(found, hit)
  }
  found
}

# Score a parsed vector: fraction parsed, plus a large bonus if it actually
# carries a time of day. A date-only column parses "successfully" while
# silently destroying the join, so the bonus has to dominate.
score_parse <- function(ts) {
  ok <- mean(!is.na(ts))
  if (ok == 0) return(-1)
  hods <- length(unique(format(ts[!is.na(ts)], "%H")))
  ok + (hods > 1) * 10
}

tidy_weather <- function(df) {
  cols <- candidate_time_cols(df)
  if (length(cols) == 0) {
    stop("No timestamp-like column found. Columns present: ",
         paste(names(df), collapse = ", "))
  }
  cat("  candidate time columns: ", paste(cols, collapse = ", "), "\n", sep = "")

  best <- NULL; best_col <- NA; best_fmt <- NA; best_score <- -1
  for (col in cols) {
    x <- trimws(as.character(df[[col]]))
    cat("  trying '", col, "' - samples: ",
        paste(utils::head(x, 2), collapse = " | "), "\n", sep = "")
    for (fmt in TIME_FORMATS) {
      ts <- suppressWarnings(as.POSIXct(x, format = fmt, tz = "UTC"))
      sc <- score_parse(ts)
      if (sc > best_score) { best <- ts; best_col <- col; best_fmt <- fmt; best_score <- sc }
    }
  }

  # If no explicit format worked, let R guess on the best-looking column.
  if (best_score < 0) {
    x <- trimws(as.character(df[[cols[1]]]))
    best <- tryCatch(suppressWarnings(as.POSIXct(x, tz = "UTC")),
                     error = function(e) rep(as.POSIXct(NA, tz = "UTC"), length(x)))
    best_col <- cols[1]; best_fmt <- "auto"
    if (all(is.na(best))) {
      stop("Could not parse any timestamp. Samples from '", cols[1], "': ",
           paste(utils::head(x, 3), collapse = " | "))
    }
  }

  hods <- length(unique(format(best[!is.na(best)], "%H")))
  cat("  CHOSEN: column '", best_col, "' with format '", best_fmt, "' - ",
      round(100 * mean(!is.na(best))), "% parsed, ", hods,
      " distinct hours-of-day\n", sep = "")

  if (hods <= 1) {
    cat("\n  *** WARNING ***\n")
    cat("  The timestamps carry no time of day, so every reading collapses onto\n")
    cat("  midnight and the join to bike data will find nothing. The column\n")
    cat("  samples printed above show what MeteoSwiss actually sent - if they do\n")
    cat("  contain a time, the format list in TIME_FORMATS needs the matching\n")
    cat("  pattern adding.\n\n")
  }

  out <- data.frame(hour = best, stringsAsFactors = FALSE)
  station_col <- find_col(df, "station", "abbr")
  if (!is.null(station_col)) out$weather_station_abbr <- df[[station_col]]

  renamed <- 0
  for (nm in names(df)) {
    key <- tolower(trimws(nm))
    if (identical(nm, best_col) || identical(nm, station_col)) next
    target <- if (key %in% names(PARAM_NAMES)) {
      renamed <- renamed + 1; PARAM_NAMES[[key]]
    } else key
    out[[target]] <- suppressWarnings(as.numeric(df[[nm]]))
  }

  out <- out[!is.na(out$hour), ]
  out <- out[order(out$hour), ]
  # Snap to the exact hour so the key matches the bike side, and drop any
  # duplicates introduced by overlapping 'now' and 'recent' files.
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
  ranked <- NULL
  if (!is.null(opts$stations)) {
    bikes <- read.csv(opts$stations, stringsAsFactors = FALSE)
    clat <- mean(as.numeric(bikes$lat), na.rm = TRUE)
    clon <- mean(as.numeric(bikes$lon), na.rm = TRUE)
    cat(sprintf("\nBike network centroid: %.4f, %.4f  (%d stations)\n",
                clat, clon, nrow(bikes)))

    # A centroid only means something if the stations cluster around it.
    #
    # This is not hypothetical: collecting the whole Swiss network unfiltered
    # puts the centroid at 46.92, 7.92 - empty countryside between the cities,
    # near no bike station at all - and the "nearest" weather station comes out
    # as Schüpfheim, a rural site representing Bern, Basel, Zürich and Ticino
    # at once. The join still runs. It just measures nothing.
    spread <- haversine_km(clat, clon, as.numeric(bikes$lat), as.numeric(bikes$lon))
    cat(sprintf("Station spread from centroid: median %.1f km, 90th pct %.1f km, max %.1f km\n",
                median(spread, na.rm = TRUE),
                quantile(spread, 0.9, na.rm = TRUE), max(spread, na.rm = TRUE)))
    if (quantile(spread, 0.9, na.rm = TRUE) > 15) {
      cat("\n  *** WARNING ***\n")
      cat("  These stations are spread over tens of kilometres, so one weather\n")
      cat("  station cannot represent them - least of all for precipitation,\n")
      cat("  which MeteoSwiss itself notes is highly variable in space.\n")
      cat("  Collect a single city (01_collect_publibike.R --city Bern), or\n")
      cat("  split the network by city and fetch weather for each.\n\n")
    }

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

  # Being NEAREST does not mean being USABLE.
  #
  # Bantiger sits 7 km from the centre of Bern and is listed as an "automatic
  # weather station", but it publishes only radiation and sunshine - no
  # temperature, no precipitation. Selected blindly it yields a weather table
  # with empty columns, and 04 then joins successfully against nothing at all.
  # So: fetch, check the parameters the analysis actually needs are populated,
  # and if they are not, move down the list of nearest stations.
  REQUIRED <- c("temp_c", "precip_mm")

  fetch_one <- function(a) {
    cat("\nFetching hourly data for", a, "\n")
    hrefs <- tryCatch(find_hourly_assets(a), error = function(e) {
      cat("  no hourly assets:", conditionMessage(e), "\n"); NULL })
    if (is.null(hrefs)) return(NULL)
    parts <- list()
    for (h in hrefs) {
      nm <- basename(h)
      if (!opts$historical && grepl("historical", tolower(nm))) next
      cat("  downloading", nm, "\n")
      parts[[length(parts) + 1]] <- read_ms_csv(h)
    }
    if (length(parts) == 0) return(NULL)
    common <- Reduce(intersect, lapply(parts, names))
    raw <- do.call(rbind, lapply(parts, function(p) p[, common, drop = FALSE]))
    tidy_weather(raw)
  }

  usable <- function(d) {
    if (is.null(d)) return(FALSE)
    have <- vapply(REQUIRED, function(v) v %in% names(d) && any(!is.na(d[[v]])),
                   logical(1))
    if (all(have)) return(TRUE)
    cat("  UNUSABLE: no data for ", paste(REQUIRED[!have], collapse = ", "),
        ". This station does not measure them.\n", sep = "")
    FALSE
  }

  tidy <- fetch_one(abbr)

  # Only walk the list when the station was chosen automatically. An explicit
  # --station-abbr is an instruction, so it fails loudly instead.
  if (!usable(tidy)) {
    if (!is.null(opts$abbr) || is.null(ranked)) {
      stop("Station '", abbr, "' publishes no ",
           paste(REQUIRED, collapse = "/"), ". Choose another with --station-abbr, ",
           "or run --list to see what is nearby.")
    }
    for (i in seq_len(min(6, nrow(ranked)))) {
      cand <- ranked$weather_station_abbr[i]
      if (identical(cand, abbr)) next
      cat("\n-> falling back to the next nearest station: ", cand,
          sprintf(" (%.1f km)\n", ranked$distance_km[i]), sep = "")
      tidy <- fetch_one(cand)
      if (usable(tidy)) { abbr <- cand; break }
    }
    if (!usable(tidy)) {
      stop("None of the nearest stations publish ", paste(REQUIRED, collapse = "/"), ".")
    }
    cat("\nUsing ", abbr, " instead.\n", sep = "")
  }

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
