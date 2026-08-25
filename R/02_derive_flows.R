#!/usr/bin/env Rscript
# ============================================================================
# 02_derive_flows.R
#
# Turn the accumulated station-status snapshots into analysis tables.
#
# The collector records a STOCK series: how many bikes sat at each station in
# each published snapshot. The interesting questions are about FLOWS: bikes
# leaving, bikes arriving. This script differences the stock series to infer
# those flows and joins in the station dimension table.
#
# It also reports the things a methods section needs and the raw files do not
# state: how often the feed published, how much of the network was reporting at
# all, how many duplicate or out-of-order rows were dropped, and how much of the
# window the collector was actually polling.
#
# Usage:
#   Rscript 02_derive_flows.R                       # reads ./data, writes ./derived
#   Rscript 02_derive_flows.R --data data --out derived
#   Rscript 02_derive_flows.R --all-stations        # ignore the current scope
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

# A single observation interval should not see a large swing at one station from
# organic use alone. Bigger jumps are almost certainly the rebalancing van.
# Flagged, not dropped: whether to exclude them is a decision you should make
# explicitly and defend in the writeup.
#
# Note that the interval is ~15 minutes, not the 1-5 minutes originally planned
# (docs/DATA_QUALITY.md), so this threshold is doing more work than intended -
# more organic activity can accumulate within one window. Check how many events
# it flags before treating the flag as reliable.
REBALANCE_THRESHOLD <- 5

parse_args <- function(args) {
  opts <- list(data = "data", out = "derived", all_stations = FALSE)
  i <- 1
  while (i <= length(args)) {
    if (args[[i]] == "--data") { i <- i + 1; opts$data <- args[[i]] }
    else if (args[[i]] == "--out") { i <- i + 1; opts$out <- args[[i]] }
    else if (args[[i]] == "--all-stations") opts$all_stations <- TRUE
    else stop("Unknown argument: ", args[[i]])
    i <- i + 1
  }
  opts
}

# ---- loading ---------------------------------------------------------------

as_utc <- function(x) {
  if (inherits(x, "POSIXct")) return(x)
  as.POSIXct(as.character(x), format = "%Y-%m-%dT%H:%M:%S", tz = "UTC")
}

# Older status files (before the collector recorded feed_last_updated) are
# padded with NA so both vintages can be loaded together.
bind_status <- function(parts) {
  cols <- Reduce(union, lapply(parts, names))
  parts <- lapply(parts, function(p) {
    for (m in setdiff(cols, names(p))) p[[m]] <- NA
    p[, cols, drop = FALSE]
  })
  do.call(rbind, parts)
}

load_status <- function(data_dir) {
  files <- list.files(file.path(data_dir, "station_status"),
                      pattern = "^status_.*\\.csv\\.gz$", full.names = TRUE)
  if (length(files) == 0) {
    stop("No status files under ", file.path(data_dir, "station_status"),
         ". Has the collector run yet?")
  }
  df <- bind_status(lapply(files, function(f) read.csv(gzfile(f), stringsAsFactors = FALSE)))
  n_raw <- nrow(df)

  df$polled_at_utc <- as_utc(df$polled_at_utc)
  df$station_id <- as.character(df$station_id)
  df <- df[!is.na(df$polled_at_utc), ]

  if ("last_reported" %in% names(df)) {
    df$last_reported <- suppressWarnings(as_utc(df$last_reported))
  } else {
    df$last_reported <- as.POSIXct(NA, tz = "UTC")
  }

  # The observation time is the feed's own publication clock, not the moment we
  # happened to ask. Poll time carries up to a full publication interval of
  # jitter relative to when the data was actually current.
  if ("feed_last_updated" %in% names(df)) {
    df$observed_at <- as_utc(df$feed_last_updated)
    df$observed_at[is.na(df$observed_at)] <- df$polled_at_utc[is.na(df$observed_at)]
  } else if (any(!is.na(df$last_reported))) {
    # RECOVERY PATH for data collected before feed_last_updated was recorded.
    #
    # Those files have one row per poll, so a 60-second poll of a feed that
    # publishes every ~15 minutes stored the same snapshot ~15 times, and the
    # out-of-step replicas (docs/DATA_QUALITY.md §2) mean the sequence sometimes
    # returns to a snapshot already recorded. Differencing that in poll order
    # invents a departure and a matching arrival at every station that moved in
    # between - measured at 3.9% of polls in the 24-25 Aug data.
    #
    # The newest last_reported in a poll identifies the snapshot it came from.
    # On the 24-25 Aug data that mapping is exactly one-to-one: 619 polls, 39
    # distinct network states, 39 distinct max(last_reported). Using it as the
    # observation key collapses the repeats and restores the true series.
    key <- as.numeric(df$polled_at_utc)
    snap <- ave(as.numeric(df$last_reported), key,
                FUN = function(v) if (all(is.na(v))) NA_real_ else max(v, na.rm = TRUE))
    df$observed_at <- as.POSIXct(snap, origin = "1970-01-01", tz = "UTC")
    df$observed_at[is.na(df$observed_at)] <- df$polled_at_utc[is.na(df$observed_at)]
    cat(sprintf("No feed_last_updated column: recovered %d distinct snapshots from %d polls\n",
                length(unique(df$observed_at)), length(unique(df$polled_at_utc))))
    cat("       (older collector; snapshot identity taken from max(last_reported))\n")
  } else {
    df$observed_at <- df$polled_at_utc
  }

  # One row per station per published snapshot. Duplicates arise when two
  # collector runs overlap, when the watchdog fires alongside a live chain, or
  # when a replica re-serves a snapshot already recorded. Differencing a
  # duplicated series double-counts every flow, so they go before anything else.
  key <- paste(df$station_id, as.numeric(df$observed_at))
  dup <- duplicated(key)
  if (any(dup)) {
    cat(sprintf("Dropped %s duplicate station-snapshot rows (%.1f%% of the file)\n",
                format(sum(dup), big.mark = ","), 100 * mean(dup)))
    df <- df[!dup, ]
  }

  cat(sprintf("Loaded %s status rows from %d file(s), %s after de-duplication\n  %s to %s\n",
              format(n_raw, big.mark = ","), length(files),
              format(nrow(df), big.mark = ","),
              min(df$observed_at), max(df$observed_at)))

  n_snap <- length(unique(df$observed_at))
  if (n_snap > 1) {
    d <- diff(sort(unique(as.numeric(df$observed_at)))) / 60
    cat(sprintf("  %d distinct snapshots; interval between them: median %.1f min, max %.1f min\n",
                n_snap, median(d), max(d)))
  }
  df
}

load_stations <- function(data_dir, all_stations = FALSE) {
  files <- list.files(file.path(data_dir, "station_information"),
                      pattern = "^stations_.*\\.csv$", full.names = TRUE)
  if (length(files) == 0) stop("No station files under ", data_dir)
  df <- bind_status(lapply(files, read.csv, stringsAsFactors = FALSE))
  df$station_id <- as.character(df$station_id)

  # The most recent dimension fetch defines the CURRENT SCOPE.
  #
  # This matters whenever the collector's scope has changed. Earlier runs of
  # this project collected all 1,663 Swiss stations; collection is now scoped to
  # Bern. Without this filter those old nationwide rows are pulled back in, the
  # station centroid moves to the middle of the country, and 03_fetch_meteoswiss
  # picks a rural weather station to represent a city network - which is exactly
  # the failure the scoping was introduced to avoid.
  #
  # Pass --all-stations to analyse everything ever collected instead.
  latest <- max(df$fetched_at_utc, na.rm = TRUE)
  in_scope <- df$station_id[df$fetched_at_utc == latest]

  # keep the most recent record per station
  df <- df[order(df$fetched_at_utc), ]
  df <- df[!duplicated(df$station_id, fromLast = TRUE), ]

  if (!all_stations && length(in_scope) && length(in_scope) < nrow(df)) {
    cat(sprintf("Scope: %d stations in the latest dimension fetch (%s); ",
                length(in_scope), latest))
    cat(sprintf("ignoring %d from earlier, wider collection runs.\n",
                nrow(df) - length(in_scope)))
    cat("       Pass --all-stations to include them.\n")
    df <- df[df$station_id %in% in_scope, ]
  }
  cat(sprintf("Loaded %d unique stations\n", nrow(df)))
  df
}

# ---- vehicle type split ----------------------------------------------------
# bikes_by_type holds a small JSON object, e.g. {"1":4,"2":3}. Parse it with a
# regex rather than pulling in jsonlite, so this script stays dependency-free.

expand_vehicle_types <- function(df) {
  blob <- df$bikes_by_type
  if (is.null(blob) || all(is.na(blob)) || all(blob == "")) return(df)
  blob[is.na(blob)] <- ""

  # Vehicle type ids in this feed are "PIB:VehicleType:ebike" - they contain
  # colons. Stripping punctuation from the id before rebuilding the search
  # pattern (as an earlier version did) produced a pattern that could never
  # match its own blob, so every bikes_type_* column came out silently zero and
  # the e-bike-versus-classic question could not be asked at all. Keep the id
  # exactly as it appears, and escape it for the regex.
  ids <- unique(unlist(regmatches(blob, gregexpr('"[^"]+"\\s*:', blob))))
  ids <- sub('"\\s*:$', "", sub('^"', "", ids))
  ids <- ids[nzchar(ids)]
  if (length(ids) == 0) return(df)

  # Column suffix: the last colon-separated part ("ebike"), unless that would
  # collide, in which case the whole id with punctuation folded to underscores.
  short <- vapply(strsplit(ids, ":", fixed = TRUE), function(p) p[length(p)], character(1))
  if (anyDuplicated(short)) short <- gsub("[^A-Za-z0-9]+", "_", ids)

  for (i in seq_along(ids)) {
    # \Q...\E quotes the id literally, so colons and any other punctuation in it
    # are matched as themselves rather than as regex syntax. Needs perl = TRUE.
    pat <- paste0('\\Q"', ids[i], '"\\E\\s*:\\s*([0-9]+)')
    vals <- rep(NA_integer_, length(blob))
    hit <- grepl(pat, blob, perl = TRUE)
    if (any(hit)) {
      vals[hit] <- as.integer(sub(paste0(".*", pat, ".*"), "\\1", blob[hit], perl = TRUE))
    }
    # A type absent from a station's blob is a genuine zero; a station with no
    # blob at all is unknown, and must not be counted as zero.
    vals[!hit & nzchar(blob)] <- 0L
    df[[paste0("bikes_type_", short[i])]] <- vals
  }

  totals <- vapply(short, function(s) sum(df[[paste0("bikes_type_", s)]], na.rm = TRUE), numeric(1))
  cat(sprintf("Split bike counts across %d vehicle type(s): %s\n", length(ids),
              paste(sprintf("%s (%s bikes)", short, format(totals, big.mark = ",", trim = TRUE)),
                    collapse = ", ")))
  if (all(totals == 0)) {
    cat("  WARNING: every vehicle-type column summed to zero - check bikes_by_type in the raw file.\n")
  }
  df
}

# ---- flow inference --------------------------------------------------------

derive_events <- function(status) {
  status <- status[order(status$station_id, status$observed_at), ]
  g <- status$station_id

  lag_by <- function(v) ave(v, g, FUN = function(x) c(NA, head(x, -1)))

  status$prev_bikes <- lag_by(status$num_bikes_available)
  t_num <- as.numeric(status$observed_at)
  status$prev_time  <- lag_by(t_num)

  status$delta        <- status$num_bikes_available - status$prev_bikes
  status$gap_minutes  <- (t_num - status$prev_time) / 60

  # WHEN did the change happen?
  #
  # Two clocks are available. `observed_at` is when the feed published the new
  # value - accurate to the publication cadence, ~15 minutes. `last_reported`
  # is the station's own account of when it last changed, at second resolution.
  # The second is far better, so it is used whenever it is credible: it must
  # fall inside the interval between the previous and current observation.
  # Outside that interval it is describing some earlier change, not this one.
  lr <- as.numeric(status$last_reported)
  credible <- !is.na(lr) & !is.na(status$prev_time) &
    lr > status$prev_time & lr <= t_num + 60
  status$event_at <- as.POSIXct(ifelse(credible, lr, t_num),
                                origin = "1970-01-01", tz = "UTC")
  status$event_time_source <- ifelse(credible, "last_reported", "snapshot")

  # Per-vehicle-type flows. Q3 (are e-bike users less weather-sensitive?) needs
  # departures split by type, and the totals cannot be split after the fact.
  # A type can move while the total does not - one e-bike out, one classic in -
  # so those rows count as events even though delta is zero.
  type_cols <- grep("^bikes_type_", names(status), value = TRUE)
  any_type_moved <- rep(FALSE, nrow(status))
  for (tc in type_cols) {
    d <- status[[tc]] - lag_by(status[[tc]])
    status[[paste0("delta_", sub("^bikes_type_", "", tc))]] <- d
    any_type_moved <- any_type_moved | (!is.na(d) & d != 0)
  }

  keep <- (!is.na(status$delta) & status$delta != 0) | any_type_moved
  ev <- status[keep, ]
  ev$departures <- pmax(0, -ev$delta)
  ev$arrivals   <- pmax(0,  ev$delta)
  for (tc in type_cols) {
    s <- sub("^bikes_type_", "", tc)
    d <- ev[[paste0("delta_", s)]]
    ev[[paste0("departures_", s)]] <- pmax(0, -d)
    ev[[paste0("arrivals_", s)]]   <- pmax(0,  d)
  }
  ev$likely_rebalancing <- abs(ev$delta) >= REBALANCE_THRESHOLD

  cat(sprintf("Derived %s change events (%s flagged as likely rebalancing, |delta| >= %d)\n",
              format(nrow(ev), big.mark = ","),
              format(sum(ev$likely_rebalancing), big.mark = ","),
              REBALANCE_THRESHOLD))
  if (nrow(ev) > 0) {
    pc <- 100 * mean(ev$event_time_source == "last_reported")
    cat(sprintf("  %.0f%% timestamped from the station's own last_reported, the rest from the snapshot\n", pc))
    cat(sprintf("  observation gap before an event: median %.1f min, max %.1f min\n",
                median(ev$gap_minutes, na.rm = TRUE), max(ev$gap_minutes, na.rm = TRUE)))
  }

  cols <- c("event_at", "observed_at", "polled_at_utc", "event_time_source",
            "station_id", "prev_bikes", "num_bikes_available",
            "delta", "departures", "arrivals", "gap_minutes", "likely_rebalancing",
            grep("^(departures|arrivals)_", names(ev), value = TRUE))
  ev[, intersect(cols, names(ev))]
}

# Collection uptime, from the collector's own poll log.
#
# The log records every poll attempt, whether or not it produced data, so
# "the feed published nothing for 40 minutes" can be told apart from "the
# collector was down for 40 minutes". Without it, both look identical in the
# status series - a gap - and the methods section can only guess which.
report_coverage <- function(data_dir, status) {
  files <- list.files(file.path(data_dir, "poll_log"),
                      pattern = "^polls_.*\\.csv$", full.names = TRUE)
  if (length(files) == 0) {
    cat("\nNo poll log found (data/poll_log/). Collection gaps cannot be\n")
    cat("distinguished from feed gaps - the collector writes this log from now on.\n")
    return(invisible(NULL))
  }
  pl <- do.call(rbind, lapply(files, read.csv, stringsAsFactors = FALSE))
  pl$probe_at_utc <- as_utc(pl$probe_at_utc)
  pl <- pl[!is.na(pl$probe_at_utc), ]
  pl <- pl[order(pl$probe_at_utc), ]

  cat(sprintf("\nCollector poll log: %s polls, %s to %s\n",
              format(nrow(pl), big.mark = ","),
              min(pl$probe_at_utc), max(pl$probe_at_utc)))
  tab <- table(pl$action)
  for (nm in names(tab)) {
    cat(sprintf("  %-22s %6d  (%.1f%%)\n", nm, tab[[nm]], 100 * tab[[nm]] / nrow(pl)))
  }
  if (nrow(pl) > 1) {
    g <- as.numeric(diff(pl$probe_at_utc), units = "mins")
    down <- g[g > 5]
    cat(sprintf("  gaps in POLLING over 5 min: %d, totalling %.0f min",
                length(down), sum(down)))
    cat(sprintf("  (%.1f%% of the window)\n",
                100 * sum(down) / as.numeric(difftime(max(pl$probe_at_utc),
                                                      min(pl$probe_at_utc), units = "mins"))))
    cat("  Anything else is the feed not publishing, not the collector missing it.\n")
  }
  invisible(NULL)
}

# How much of the network is actually alive?
#
# 69% of stations network-wide had not reported for over an hour when this was
# written, and 17% not for over a day. A station that is silent contributes a
# long run of identical readings, which differencing correctly reads as zero
# flow - but zero flow because nobody rode, and zero flow because the station is
# offline, are different things and must not be averaged together.
report_liveness <- function(status) {
  if (all(is.na(status$last_reported))) {
    cat("\nNo last_reported column - liveness cannot be assessed.\n")
    return(invisible(NULL))
  }
  latest <- status[!duplicated(status$station_id, fromLast = TRUE), ]
  age_h <- as.numeric(difftime(max(status$observed_at), latest$last_reported,
                               units = "hours"))
  age_h <- age_h[!is.na(age_h)]
  if (!length(age_h)) return(invisible(NULL))
  cat("\nStation liveness at the end of the window (age of last_reported):\n")
  cat(sprintf("  reported within 1h:  %3d of %3d (%.0f%%)\n",
              sum(age_h < 1), length(age_h), 100 * mean(age_h < 1)))
  cat(sprintf("  within 24h:          %3d (%.0f%%)\n",
              sum(age_h < 24), 100 * mean(age_h < 24)))
  cat(sprintf("  silent over 24h:     %3d (%.0f%%)  <- these contribute flat zero flow\n",
              sum(age_h >= 24), 100 * mean(age_h >= 24)))
  cat(sprintf("  median age: %.1f h\n", median(age_h)))
  invisible(NULL)
}

floor_hour <- function(x) {
  as.POSIXct(floor(as.numeric(x) / 3600) * 3600, origin = "1970-01-01", tz = "UTC")
}

derive_hourly <- function(status, events, stations) {
  status$hour <- floor_hour(status$observed_at)

  # Occupancy comes from the stock series and always exists.
  occ <- aggregate(num_bikes_available ~ station_id + hour, data = status,
                   FUN = function(v) c(mean = mean(v), min = min(v), max = max(v)))
  occ <- do.call(data.frame, occ)
  names(occ) <- c("station_id", "hour", "mean_bikes", "min_bikes", "max_bikes")

  # Flows may legitimately be empty: a short collection window, or a quiet
  # period where no station changed between polls. Build a zero-row frame with
  # the right columns rather than letting aggregate() fail on no rows.
  flow_cols <- c("station_id", "hour", "departures", "arrivals",
                 "rebalancing_events", "events")
  if (nrow(events) == 0) {
    cat("NOTE: no change events in this window - flows will all be zero.\n",
        "     With a real feed this means the window was too short or too quiet.\n", sep = "")
    flow <- setNames(data.frame(character(0), as.POSIXct(character(0), tz = "UTC"),
                                numeric(0), numeric(0), numeric(0), numeric(0),
                                stringsAsFactors = FALSE), flow_cols)
  } else {
    # Bucket by when the change happened, not when it was seen. With a ~15
    # minute publication cadence these differ often enough to move events
    # across an hour boundary, which is exactly the boundary the weather join
    # depends on.
    events$hour <- floor_hour(events$event_at)
    sum_cols <- c("departures", "arrivals", "likely_rebalancing",
                  grep("^(departures|arrivals)_", names(events), value = TRUE))
    flow <- aggregate(events[, sum_cols, drop = FALSE],
                      by = list(station_id = events$station_id, hour = events$hour),
                      FUN = function(v) sum(v, na.rm = TRUE))
    names(flow)[names(flow) == "likely_rebalancing"] <- "rebalancing_events"

    n_ev <- aggregate(delta ~ station_id + hour, data = events, FUN = length)
    names(n_ev)[3] <- "events"
    flow <- merge(flow, n_ev, by = c("station_id", "hour"), all.x = TRUE)
  }

  out <- merge(occ, flow, by = c("station_id", "hour"), all.x = TRUE)
  # A station-hour with no event row had no movement, which is a zero, not a
  # missing value. Covers the per-type columns too.
  zero_cols <- c("departures", "arrivals", "events", "rebalancing_events",
                 grep("^(departures|arrivals)_", names(out), value = TRUE))
  for (v in intersect(zero_cols, names(out))) out[[v]][is.na(out[[v]])] <- 0

  out$net_flow <- out$arrivals - out$departures
  out$turnover <- out$arrivals + out$departures
  for (s in sub("^departures_", "", grep("^departures_", names(out), value = TRUE))) {
    out[[paste0("turnover_", s)]] <- out[[paste0("arrivals_", s)]] + out[[paste0("departures_", s)]]
  }

  # How many snapshots actually covered this station-hour. An hour built from
  # one observation is not comparable with one built from four; without this
  # column a partly-collected hour looks like a quiet hour.
  nobs <- aggregate(list(observations = status$num_bikes_available),
                    by = list(station_id = status$station_id, hour = status$hour),
                    FUN = length)
  out <- merge(out, nobs, by = c("station_id", "hour"), all.x = TRUE)

  keep <- intersect(c("station_id", "name", "lat", "lon", "capacity", "post_code",
                      "region_id"), names(stations))
  out <- merge(out, stations[, keep], by = "station_id", all.x = TRUE)

  out$fill_rate   <- ifelse(out$capacity > 0, out$mean_bikes / out$capacity, NA)
  out$is_empty    <- out$min_bikes == 0
  # NOMINAL, not measured. Every station in this feed is is_virtual_station,
  # `capacity` is an allowance rather than a count of physical docks, and the
  # feed publishes no num_docks_available. Treat this as "at nominal capacity",
  # and do not build a dock-saturation claim on it.
  out$at_nominal_capacity <- out$max_bikes >= out$capacity
  out$hour_of_day <- as.integer(format(out$hour, "%H", tz = "UTC"))
  out$day_of_week <- weekdays(out$hour)
  out$is_weekend  <- format(out$hour, "%u", tz = "UTC") %in% c("6", "7")

  cat(sprintf("Built %s station-hour rows\n", format(nrow(out), big.mark = ",")))
  out[order(out$station_id, out$hour), ]
}

# ---- main ------------------------------------------------------------------

main <- function() {
  opts <- parse_args(commandArgs(trailingOnly = TRUE))
  dir.create(opts$out, recursive = TRUE, showWarnings = FALSE)

  status   <- expand_vehicle_types(load_status(opts$data))
  stations <- load_stations(opts$data, opts$all_stations)

  # Status rows for stations outside the current scope would otherwise survive
  # into the hourly table as rows with no name, capacity or coordinates.
  keep <- status$station_id %in% stations$station_id
  if (!all(keep)) {
    cat(sprintf("Dropped %s status rows for %d out-of-scope stations\n",
                format(sum(!keep), big.mark = ","),
                length(unique(status$station_id[!keep]))))
    status <- status[keep, ]
  }
  if (nrow(status) == 0) {
    stop("No status rows left after scoping. If you deliberately changed the ",
         "collection scope, run with --all-stations to see everything.")
  }

  report_coverage(opts$data, status)
  report_liveness(status)
  events   <- derive_events(status)
  hourly   <- derive_hourly(status, events, stations)

  write.csv(events,   file.path(opts$out, "events.csv"),       row.names = FALSE)
  write.csv(hourly,   file.path(opts$out, "hourly_flow.csv"),  row.names = FALSE)
  write.csv(stations, file.path(opts$out, "stations.csv"),     row.names = FALSE)

  cat(sprintf("\nWrote:\n  %s\n  %s\n  %s\n",
              file.path(opts$out, "events.csv"),
              file.path(opts$out, "hourly_flow.csv"),
              file.path(opts$out, "stations.csv")))

  busiest <- aggregate(turnover ~ name, data = hourly, FUN = sum)
  busiest <- head(busiest[order(-busiest$turnover), ], 5)
  cat("\nBusiest stations so far (total bike movements):\n")
  for (i in seq_len(nrow(busiest))) {
    cat(sprintf("  %-40s %6d\n", busiest$name[i], busiest$turnover[i]))
  }
}

main()
