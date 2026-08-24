#!/usr/bin/env Rscript
# ============================================================================
# 02_derive_flows.R
#
# Turn the accumulated station-status snapshots into analysis tables.
#
# The collector records a STOCK series: how many bikes sat at each station at
# each poll. The interesting questions are about FLOWS: bikes leaving, bikes
# arriving. This script differences the stock series to infer those flows and
# joins in the station dimension table.
#
# Usage:
#   Rscript 02_derive_flows.R                       # reads ./data, writes ./derived
#   Rscript 02_derive_flows.R --data data --out derived
#
# Dependencies: base R only.
# ============================================================================

# A single poll interval should not see a large swing at one station from
# organic use alone. Bigger jumps are almost certainly the rebalancing van.
# Flagged, not dropped: whether to exclude them is a decision you should make
# explicitly and defend in the writeup.
REBALANCE_THRESHOLD <- 5

parse_args <- function(args) {
  opts <- list(data = "data", out = "derived")
  i <- 1
  while (i <= length(args)) {
    if (args[[i]] == "--data") { i <- i + 1; opts$data <- args[[i]] }
    else if (args[[i]] == "--out") { i <- i + 1; opts$out <- args[[i]] }
    else stop("Unknown argument: ", args[[i]])
    i <- i + 1
  }
  opts
}

# ---- loading ---------------------------------------------------------------

load_status <- function(data_dir) {
  files <- list.files(file.path(data_dir, "station_status"),
                      pattern = "^status_.*\\.csv\\.gz$", full.names = TRUE)
  if (length(files) == 0) {
    stop("No status files under ", file.path(data_dir, "station_status"),
         ". Has the collector run yet?")
  }
  parts <- lapply(files, function(f) read.csv(gzfile(f), stringsAsFactors = FALSE))
  df <- do.call(rbind, parts)

  df$polled_at_utc <- as.POSIXct(df$polled_at_utc, format = "%Y-%m-%dT%H:%M:%S",
                                 tz = "UTC")
  df$station_id <- as.character(df$station_id)
  df <- df[!is.na(df$polled_at_utc), ]

  cat(sprintf("Loaded %s status rows from %d file(s)\n  %s to %s\n",
              format(nrow(df), big.mark = ","), length(files),
              min(df$polled_at_utc), max(df$polled_at_utc)))
  df
}

load_stations <- function(data_dir) {
  files <- list.files(file.path(data_dir, "station_information"),
                      pattern = "^stations_.*\\.csv$", full.names = TRUE)
  if (length(files) == 0) stop("No station files under ", data_dir)
  df <- do.call(rbind, lapply(files, read.csv, stringsAsFactors = FALSE))
  df$station_id <- as.character(df$station_id)

  # keep the most recent record per station
  df <- df[order(df$fetched_at_utc), ]
  df <- df[!duplicated(df$station_id, fromLast = TRUE), ]
  cat(sprintf("Loaded %d unique stations\n", nrow(df)))
  df
}

# ---- vehicle type split ----------------------------------------------------
# bikes_by_type holds a small JSON object, e.g. {"1":4,"2":3}. Parse it with a
# regex rather than pulling in jsonlite, so this script stays dependency-free.

expand_vehicle_types <- function(df) {
  blob <- df$bikes_by_type
  if (is.null(blob) || all(is.na(blob)) || all(blob == "")) return(df)

  ids <- unique(unlist(regmatches(blob, gregexpr('"[^"]+"\\s*:', blob))))
  ids <- gsub('["[:space:]:]', "", ids)
  ids <- ids[nzchar(ids)]
  if (length(ids) == 0) return(df)

  for (id in ids) {
    pat <- paste0('"', id, '"\\s*:\\s*([0-9]+)')
    m <- regmatches(blob, regexpr(pat, blob))
    vals <- rep(0L, length(blob))
    hit <- nzchar(m)
    if (any(hit)) {
      vals[hit] <- as.integer(sub(pat, "\\1", m[hit]))
    }
    df[[paste0("bikes_type_", id)]] <- vals
  }
  cat(sprintf("Split bike counts across %d vehicle type(s): %s\n",
              length(ids), paste(ids, collapse = ", ")))
  df
}

# ---- flow inference --------------------------------------------------------

derive_events <- function(status) {
  status <- status[order(status$station_id, status$polled_at_utc), ]

  lag_by_station <- function(x, g) unlist(lapply(split(x, g), function(v) c(NA, head(v, -1))),
                                          use.names = FALSE)
  g <- factor(status$station_id, levels = unique(status$station_id))
  status <- status[order(status$station_id, status$polled_at_utc), ]
  g <- status$station_id

  status$prev_bikes <- ave(status$num_bikes_available, g,
                           FUN = function(v) c(NA, head(v, -1)))
  t_num <- as.numeric(status$polled_at_utc)
  status$prev_time <- ave(t_num, g, FUN = function(v) c(NA, head(v, -1)))

  status$delta        <- status$num_bikes_available - status$prev_bikes
  status$gap_minutes  <- (t_num - status$prev_time) / 60

  ev <- status[!is.na(status$delta) & status$delta != 0, ]
  ev$departures <- pmax(0, -ev$delta)
  ev$arrivals   <- pmax(0,  ev$delta)
  ev$likely_rebalancing <- abs(ev$delta) >= REBALANCE_THRESHOLD

  cat(sprintf("Derived %s change events (%s flagged as likely rebalancing, |delta| >= %d)\n",
              format(nrow(ev), big.mark = ","),
              format(sum(ev$likely_rebalancing), big.mark = ","),
              REBALANCE_THRESHOLD))

  ev[, c("polled_at_utc", "station_id", "prev_bikes", "num_bikes_available",
         "delta", "departures", "arrivals", "gap_minutes", "likely_rebalancing")]
}

floor_hour <- function(x) {
  as.POSIXct(floor(as.numeric(x) / 3600) * 3600, origin = "1970-01-01", tz = "UTC")
}

derive_hourly <- function(status, events, stations) {
  status$hour <- floor_hour(status$polled_at_utc)

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
    events$hour <- floor_hour(events$polled_at_utc)
    flow <- aggregate(cbind(departures, arrivals, likely_rebalancing) ~ station_id + hour,
                      data = events, FUN = sum)
    names(flow)[names(flow) == "likely_rebalancing"] <- "rebalancing_events"

    n_ev <- aggregate(delta ~ station_id + hour, data = events, FUN = length)
    names(n_ev)[3] <- "events"
    flow <- merge(flow, n_ev, by = c("station_id", "hour"), all.x = TRUE)
  }

  out <- merge(occ, flow, by = c("station_id", "hour"), all.x = TRUE)
  for (v in c("departures", "arrivals", "events", "rebalancing_events")) {
    out[[v]][is.na(out[[v]])] <- 0
  }
  out$net_flow <- out$arrivals - out$departures
  out$turnover <- out$arrivals + out$departures

  keep <- intersect(c("station_id", "name", "lat", "lon", "capacity", "post_code"),
                    names(stations))
  out <- merge(out, stations[, keep], by = "station_id", all.x = TRUE)

  out$fill_rate   <- ifelse(out$capacity > 0, out$mean_bikes / out$capacity, NA)
  out$is_empty    <- out$min_bikes == 0
  out$is_full     <- out$max_bikes >= out$capacity
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
  stations <- load_stations(opts$data)
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
