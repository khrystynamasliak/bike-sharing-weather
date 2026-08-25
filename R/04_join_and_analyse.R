#!/usr/bin/env Rscript
# ============================================================================
# 04_join_and_analyse.R
#
# Join the two sources and test the weather-demand relationship.
#
# Takes derived/hourly_flow.csv (PubliBike, self-collected) and
# derived/weather_hourly.csv (MeteoSwiss) and merges them on the hour. Both
# sources timestamp in UTC, so no conversion is needed - but the overlap is
# VERIFIED rather than assumed, because a silent zero-overlap join is the
# classic way this kind of project fails.
#
# Usage:
#   Rscript 04_join_and_analyse.R --derived derived
#   Rscript 04_join_and_analyse.R --derived derived --shift-weather 1
#
# The --shift-weather option addresses a real alignment issue. MeteoSwiss
# hourly values are BACKWARD-looking (16:00 covers 15:10-16:00) while the bike
# hours are forward-looking (16:00 covers 16:00-16:59), so the two windows are
# offset by roughly an hour. Run the analysis both ways and report whether the
# result is sensitive to the choice.
#
# Dependencies: base R only.
# ============================================================================

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

parse_args <- function(args) {
  opts <- list(derived = "derived", shift = 0)
  i <- 1
  while (i <= length(args)) {
    if (args[[i]] == "--derived") { i <- i + 1; opts$derived <- args[[i]] }
    else if (args[[i]] == "--shift-weather") { i <- i + 1; opts$shift <- as.numeric(args[[i]]) }
    else stop("Unknown argument: ", args[[i]])
    i <- i + 1
  }
  opts
}

# Parse an hour column WITHOUT letting R choose the format for us.
#
# write.csv drops the time part of a midnight POSIXct, so the column reads
# "2026-01-01" on the hour and "2026-01-01 13:00:00" on every other. Bare
# as.POSIXct() picks one format from the FIRST element and applies it to the
# whole vector: if row one happens to be a midnight, every reading in the file
# collapses onto midnight, the overlap check finds nothing, and it blames the
# weather script - which parsed the source perfectly well. Parse with an
# explicit format and only fall back to date-only for the rows that need it.
parse_hour <- function(x) {
  x <- trimws(as.character(x))
  ts <- suppressWarnings(as.POSIXct(x, format = "%Y-%m-%d %H:%M:%S", tz = "UTC"))
  gap <- is.na(ts) & nzchar(x) & !is.na(x)
  if (any(gap)) {
    ts[gap] <- suppressWarnings(as.POSIXct(x[gap], format = "%Y-%m-%dT%H:%M:%S", tz = "UTC"))
  }
  gap <- is.na(ts) & nzchar(x) & !is.na(x)
  if (any(gap)) {
    ts[gap] <- suppressWarnings(as.POSIXct(x[gap], format = "%Y-%m-%d %H:%M", tz = "UTC"))
  }
  gap <- is.na(ts) & nzchar(x) & !is.na(x)
  if (any(gap)) {                       # midnight, written by write.csv as a bare date
    ts[gap] <- suppressWarnings(as.POSIXct(x[gap], format = "%Y-%m-%d", tz = "UTC"))
  }
  ts
}

load_hourly <- function(path, label) {
  if (!file.exists(path)) stop("Missing ", label, ": ", path)
  df <- read.csv(path, stringsAsFactors = FALSE)
  df$hour <- parse_hour(df$hour)
  df <- df[!is.na(df$hour), ]
  if (nrow(df) == 0) stop("No parseable timestamps in ", path)

  hods <- length(unique(format(df$hour, "%H", tz = "UTC")))
  cat(sprintf("%-14s %s rows, %s to %s  (%d distinct hours-of-day)\n",
              paste0(label, ":"), format(nrow(df), big.mark = ","),
              min(df$hour), max(df$hour), hods))
  if (hods <= 1 && nrow(df) > 24) {
    cat("  WARNING: every reading sits at the same hour of day. The time part\n")
    cat("  was lost somewhere upstream; the join will find nothing.\n")
  }
  df
}

check_overlap <- function(flow, weather) {
  fh <- unique(flow$hour); wh <- unique(weather$hour)
  ov <- intersect(as.numeric(fh), as.numeric(wh))
  cat(sprintf("\nDistinct hours - bike: %d, weather: %d, overlap: %d\n",
              length(fh), length(wh), length(ov)))

  if (length(ov) == 0) {
    cat("\n--- diagnosing the zero overlap ---\n")
    cat("bike hours:    ", paste(format(utils::head(sort(fh), 3)), collapse = ", "),
        if (length(fh) > 3) " ..." else "", "\n", sep = "")
    cat("weather hours: ", paste(format(utils::head(sort(wh), 3)), collapse = ", "),
        if (length(wh) > 3) " ..." else "", "\n", sep = "")

    w_hods <- length(unique(format(wh, "%H")))
    if (w_hods <= 1) {
      cat("\nCAUSE: the weather timestamps carry no time-of-day - every reading\n")
      cat("sits at midnight. Re-run 03_fetch_meteoswiss.R and check the\n")
      cat("'parsed with format' line it now prints.\n")
    } else if (max(wh) < min(fh)) {
      cat("\nCAUSE: the weather series ends before your collection began.\n")
      cat("MeteoSwiss 'now' files lag a little; wait an hour and re-fetch.\n")
    } else if (length(fh) <= 2) {
      cat("\nCAUSE: you have only ", length(fh), " hour(s) of bike data, which does not\n", sep = "")
      cat("yet coincide with a published weather hour. This resolves itself once\n")
      cat("collection has run for a few hours - it is not a bug.\n")
    } else {
      cat("\nCAUSE: unclear. Check both sources are UTC, and try --shift-weather 1.\n")
    }
    stop("No overlapping hours - see the diagnosis above.")
  }

  if (length(ov) < length(fh) * 0.8) {
    cat(sprintf("WARNING: only %.0f%% of bike hours have weather. ",
                100 * length(ov) / length(fh)),
        "Rows outside the overlap will have missing weather values.\n")
  }
  invisible(ov)
}

build_network_hourly <- function(flow, weather) {
  agg <- function(v, fun = sum) {
    a <- aggregate(flow[[v]], by = list(hour = flow$hour), FUN = fun)
    names(a)[2] <- v; a
  }
  net <- agg("departures")
  for (v in c("arrivals", "turnover")) net <- merge(net, agg(v), by = "hour")
  names(net)[names(net) %in% c("departures", "arrivals", "turnover")] <-
    paste0("total_", c("departures", "arrivals", "turnover"))

  # Carry the per-vehicle-type flows up to the network level too.
  #
  # Without these, Q3 - are e-bike users less weather-sensitive than classic-bike
  # users? - cannot be asked of this table at all: the split exists in
  # hourly_flow.csv and stopped here. They are summed, not averaged, for the same
  # reason the totals are.
  #
  # Note they will NOT sum to total_turnover. A swap - one e-bike out, one
  # mechanical in - moves both type series while barely moving the total.
  type_cols <- grep("^(departures|arrivals|turnover)_", names(flow), value = TRUE)
  for (v in type_cols) net <- merge(net, agg(v), by = "hour")

  # How much of the network was moving at all. A useful denominator, and the
  # thing to check before comparing an early sparse hour with a later dense one.
  act <- aggregate(as.integer(flow$turnover > 0), by = list(hour = flow$hour), FUN = sum)
  names(act)[2] <- "stations_moving"
  net <- merge(net, act, by = "hour")
  if ("observations" %in% names(flow)) {
    ob <- aggregate(flow$observations, by = list(hour = flow$hour),
                    FUN = function(x) round(mean(x, na.rm = TRUE), 2))
    names(ob)[2] <- "mean_observations"
    net <- merge(net, ob, by = "hour")
  }

  emp <- aggregate(as.integer(flow$is_empty), by = list(hour = flow$hour), FUN = sum)
  names(emp)[2] <- "stations_empty"
  # Nominal capacity, not physical docks - see the note in 02_derive_flows.R.
  # `is_full` is the old name for the same thing, kept so an already-collected
  # derived/hourly_flow.csv still loads.
  full_col <- if ("at_nominal_capacity" %in% names(flow)) "at_nominal_capacity" else "is_full"
  ful <- aggregate(as.integer(flow[[full_col]]), by = list(hour = flow$hour), FUN = sum)
  names(ful)[2] <- "stations_at_nominal_capacity"
  fil <- aggregate(flow$fill_rate, by = list(hour = flow$hour),
                   FUN = function(x) mean(x, na.rm = TRUE))
  names(fil)[2] <- "mean_fill_rate"

  net <- merge(merge(merge(net, emp, by = "hour"), ful, by = "hour"), fil, by = "hour")
  net <- merge(net, weather, by = "hour", all.x = TRUE)

  net$hour_of_day <- as.integer(format(net$hour, "%H", tz = "UTC"))
  net$day_of_week <- weekdays(net$hour)
  net$is_weekend  <- format(net$hour, "%u", tz = "UTC") %in% c("6", "7")
  if ("precip_mm" %in% names(net)) {
    p <- net$precip_mm; p[is.na(p)] <- 0
    net$is_raining <- p > 0.1
  }
  net[order(net$hour), ]
}

report <- function(net) {
  cat("\n", strrep("=", 62), "\n", sep = "")
  cat("WEATHER AND DEMAND\n")
  cat(strrep("=", 62), "\n", sep = "")

  numeric_vars <- intersect(c("temp_c", "precip_mm", "wind_speed_ms",
                              "humidity_pct", "sunshine_min"), names(net))
  numeric_vars <- numeric_vars[vapply(numeric_vars,
                                      function(v) sum(!is.na(net[[v]])) > 3, logical(1))]

  if (length(numeric_vars)) {
    cat("\nCorrelation with hourly network turnover:\n")
    for (v in numeric_vars) {
      r <- cor(net$total_turnover, net[[v]], use = "complete.obs")
      cat(sprintf("  %-16s r = %+.3f\n", v, r))
    }
    cat("\n  (Raw correlations. Temperature and hour of day are heavily\n")
    cat("   confounded - both peak mid-afternoon - so treat these as\n")
    cat("   descriptive and control for hour of day before claiming an effect.)\n")
  }

  if ("is_raining" %in% names(net)) {
    wet <- net$total_turnover[net$is_raining]
    dry <- net$total_turnover[!net$is_raining]
    if (length(wet) > 0 && length(dry) > 0) {
      cat("\nRain effect (raw):\n")
      cat(sprintf("  dry hours  n=%4d  mean turnover %8.1f\n", length(dry), mean(dry)))
      cat(sprintf("  wet hours  n=%4d  mean turnover %8.1f\n", length(wet), mean(wet)))
      cat(sprintf("  difference %+.1f%%\n", (mean(wet) / mean(dry) - 1) * 100))

      # Same comparison within commuting hours only. This controls for the
      # biggest confounder without needing a full model.
      pk <- net[net$hour_of_day %in% c(7, 8, 17, 18), ]
      pw <- pk$total_turnover[pk$is_raining]
      pdd <- pk$total_turnover[!pk$is_raining]
      if (length(pw) > 0 && length(pdd) > 0) {
        cat("\n  Within commute hours only (07,08,17,18):\n")
        cat(sprintf("    dry n=%3d mean %8.1f | wet n=%3d mean %8.1f (%+.1f%%)\n",
                    length(pdd), mean(pdd), length(pw), mean(pw),
                    (mean(pw) / mean(pdd) - 1) * 100))
      }

      # A regression that controls for hour of day and weekend properly.
      if ("temp_c" %in% names(net)) {
        m <- lm(total_turnover ~ factor(hour_of_day) + is_weekend + is_raining + temp_c,
                data = net)
        co <- summary(m)$coefficients
        cat("\n  Controlling for hour of day, weekend and temperature:\n")
        for (term in c("is_rainingTRUE", "temp_c")) {
          if (term %in% rownames(co)) {
            cat(sprintf("    %-16s estimate %+8.2f   p = %.4f\n",
                        term, co[term, 1], co[term, 4]))
          }
        }
        cat(sprintf("    adjusted R-squared: %.3f\n", summary(m)$adj.r.squared))
      }
    }
  }

  cat("\nMean turnover by hour of day:\n")
  bh <- aggregate(net$total_turnover, by = list(h = net$hour_of_day), FUN = mean)
  peak <- max(bh$x)
  for (i in seq_len(nrow(bh))) {
    bar <- strrep("#", round(38 * bh$x[i] / peak))
    cat(sprintf("  %02d  %7.1f  %s\n", bh$h[i], bh$x[i], bar))
  }
}

main <- function() {
  opts <- parse_args(commandArgs(trailingOnly = TRUE))
  d <- opts$derived

  flow    <- load_hourly(file.path(d, "hourly_flow.csv"),    "Bike flows")
  weather <- load_hourly(file.path(d, "weather_hourly.csv"), "Weather")

  if (opts$shift != 0) {
    weather$hour <- weather$hour + opts$shift * 3600
    cat(sprintf("Shifted weather forward by %g hour(s) for window alignment.\n",
                opts$shift))
  }

  check_overlap(flow, weather)

  wcols <- setdiff(names(weather), "weather_station_abbr")
  joined <- merge(flow, weather[, wcols], by = "hour", all.x = TRUE)
  write.csv(joined, file.path(d, "flow_with_weather.csv"), row.names = FALSE)

  net <- build_network_hourly(flow, weather[, wcols])
  write.csv(net, file.path(d, "network_hourly.csv"), row.names = FALSE)

  report(net)

  cat(sprintf("\nWrote:\n  %s  (%s station-hours)\n  %s  (%s hours)\n",
              file.path(d, "flow_with_weather.csv"), format(nrow(joined), big.mark = ","),
              file.path(d, "network_hourly.csv"), format(nrow(net), big.mark = ",")))
}

main()
