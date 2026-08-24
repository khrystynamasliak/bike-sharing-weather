#!/usr/bin/env Rscript
# ============================================================================
# 01_collect_publibike.R
#
# Accumulate a station-status history from the PubliBike GBFS feed.
#
# GBFS is a real-time specification: it reports the state of the system now and
# retains no history. PubliBike publishes no trip archive. This script therefore
# polls the live feed on a schedule and writes each snapshot to disk, building
# the historical dataset that does not otherwise exist.
#
# Usage:
#   Rscript 01_collect_publibike.R --once              # validate setup, one snapshot
#   Rscript 01_collect_publibike.R --interval 60       # run continuously
#   Rscript 01_collect_publibike.R --interval 60 --city Bern
#
#   # bounded run, for CI: poll for 5h30m then exit cleanly
#   Rscript 01_collect_publibike.R --interval 60 --duration 330 --tag $(date +%s)
#
# --duration stops the loop after N minutes (GitHub Actions jobs are killed at
# 6 hours, so exit before that and let the next run take over).
# --tag appends a string to output filenames so each run writes its own file
# rather than appending to a shared one - important when committing to git,
# because a file that is only ever created, never modified, keeps history small.
#
# Dependencies: jsonlite  ->  install.packages("jsonlite")
# ============================================================================

suppressPackageStartupMessages({
  if (!requireNamespace("jsonlite", quietly = TRUE)) {
    stop("This script needs jsonlite. Run:  install.packages('jsonlite')")
  }
  library(jsonlite)
})

# ---- configuration ---------------------------------------------------------

DEFAULT_FEED <- "https://api.publibike.ch/v1/gbfs/v2/gbfs.json"
OUT_DIR      <- "data"

# ---- argument parsing (base R, no dependencies) ----------------------------

parse_args <- function(args) {
  opts <- list(feed = DEFAULT_FEED, outdir = OUT_DIR, interval = 300,
               once = FALSE, city = NULL, duration = NULL, tag = NULL)
  i <- 1
  while (i <= length(args)) {
    a <- args[[i]]
    if (a == "--once") {
      opts$once <- TRUE
    } else if (a == "--feed") {
      i <- i + 1; opts$feed <- args[[i]]
    } else if (a == "--outdir") {
      i <- i + 1; opts$outdir <- args[[i]]
    } else if (a == "--interval") {
      i <- i + 1; opts$interval <- as.integer(args[[i]])
    } else if (a == "--city") {
      i <- i + 1; opts$city <- args[[i]]
    } else if (a == "--duration") {
      i <- i + 1; opts$duration <- as.numeric(args[[i]])   # minutes
    } else if (a == "--tag") {
      i <- i + 1; opts$tag <- gsub("[^A-Za-z0-9_-]", "", args[[i]])
    } else {
      stop("Unknown argument: ", a)
    }
    i <- i + 1
  }
  opts
}

# Filenames carry an optional tag so concurrent or sequential runs never write
# to the same file.
tagged <- function(stem, ext, tag) {
  if (is.null(tag) || !nzchar(tag)) paste0(stem, ext) else paste0(stem, "_", tag, ext)
}

log_msg <- function(...) {
  cat(format(Sys.time(), "%Y-%m-%d %H:%M:%S"), " ", ..., "\n", sep = "")
}

utc_now   <- function() format(Sys.time(), "%Y-%m-%dT%H:%M:%S", tz = "UTC")
day_stamp <- function() format(Sys.time(), "%Y%m%d", tz = "UTC")

# ---- feed discovery --------------------------------------------------------
# GBFS 2.x nests feeds under a language key (data$en$feeds); GBFS 3.x puts them
# at data$feeds. Handle both rather than assuming one.

discover_feeds <- function(discovery_url) {
  doc <- jsonlite::fromJSON(discovery_url)
  d   <- doc$data

  feeds <- NULL
  if (!is.null(d$feeds)) {
    feeds <- d$feeds
  } else {
    for (lang in c("en", "de", "fr", "it")) {
      if (!is.null(d[[lang]]) && !is.null(d[[lang]]$feeds)) {
        feeds <- d[[lang]]$feeds
        break
      }
    }
    if (is.null(feeds)) {
      for (nm in names(d)) {
        if (!is.null(d[[nm]]$feeds)) { feeds <- d[[nm]]$feeds; break }
      }
    }
  }

  if (is.null(feeds)) {
    stop("Could not find a feed list in ", discovery_url,
         ". Top-level keys: ", paste(names(d), collapse = ", "))
  }

  endpoints <- setNames(as.character(feeds$url), as.character(feeds$name))
  log_msg("Discovered ", length(endpoints), " endpoints: ",
          paste(sort(names(endpoints)), collapse = ", "))

  for (req in c("station_information", "station_status")) {
    if (!req %in% names(endpoints)) {
      stop("Feed does not expose `", req, "`, which this project depends on. ",
           "Available: ", paste(sort(names(endpoints)), collapse = ", "))
    }
  }
  endpoints
}

# ---- helpers ---------------------------------------------------------------

col_or_na <- function(df, name) {
  if (!is.null(df[[name]])) df[[name]] else rep(NA, nrow(df))
}

# Serialise the per-vehicle-type counts into a compact JSON string so that one
# status row stays one row. Split it out later in the derive step.
encode_types <- function(vt_list) {
  if (is.null(vt_list)) return(rep("", 0))
  vapply(vt_list, function(x) {
    if (is.null(x) || length(x) == 0 || !is.data.frame(x)) return("")
    counts <- as.list(setNames(x$count, as.character(x$vehicle_type_id)))
    as.character(jsonlite::toJSON(counts, auto_unbox = TRUE))
  }, character(1))
}

append_csv <- function(path, df, gzipped = FALSE) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  is_new <- !file.exists(path)
  con <- if (gzipped) gzfile(path, open = "at") else file(path, open = "at")
  on.exit(close(con))
  utils::write.table(df, con, sep = ",", row.names = FALSE,
                     col.names = is_new, qmethod = "double")
}

matches_city <- function(stations, city) {
  if (is.null(city)) return(rep(TRUE, nrow(stations)))
  hay <- tolower(paste(col_or_na(stations, "name"),
                       col_or_na(stations, "address"),
                       col_or_na(stations, "post_code")))
  grepl(tolower(city), hay, fixed = TRUE)
}

# ---- the two datasets ------------------------------------------------------

write_station_information <- function(endpoints, outdir, city, tag = NULL) {
  doc <- jsonlite::fromJSON(endpoints[["station_information"]])
  st  <- doc$data$stations
  keep <- matches_city(st, city)
  st <- st[keep, , drop = FALSE]

  out <- data.frame(
    fetched_at_utc = utc_now(),
    station_id     = as.character(st$station_id),
    name           = col_or_na(st, "name"),
    lat            = col_or_na(st, "lat"),
    lon            = col_or_na(st, "lon"),
    capacity       = col_or_na(st, "capacity"),
    address        = col_or_na(st, "address"),
    post_code      = col_or_na(st, "post_code"),
    stringsAsFactors = FALSE
  )

  path <- file.path(outdir, "station_information",
                    tagged(paste0("stations_", day_stamp()), ".csv", tag))
  if (file.exists(path)) unlink(path)          # one clean snapshot per day
  append_csv(path, out)
  log_msg("Wrote ", nrow(out), " stations to ", path)
  out$station_id
}

poll_status <- function(endpoints, outdir, keep_ids, tag = NULL) {
  doc <- jsonlite::fromJSON(endpoints[["station_status"]])
  st  <- doc$data$stations

  sid <- as.character(st$station_id)
  if (!is.null(keep_ids) && length(keep_ids)) {
    sel <- sid %in% keep_ids
    st  <- st[sel, , drop = FALSE]
    sid <- sid[sel]
  }

  types <- if (!is.null(st$vehicle_types_available)) {
    encode_types(st$vehicle_types_available)
  } else rep("", nrow(st))

  out <- data.frame(
    polled_at_utc       = utc_now(),
    last_reported       = col_or_na(st, "last_reported"),
    station_id          = sid,
    num_bikes_available = col_or_na(st, "num_bikes_available"),
    num_docks_available = col_or_na(st, "num_docks_available"),
    num_bikes_disabled  = col_or_na(st, "num_bikes_disabled"),
    is_installed        = col_or_na(st, "is_installed"),
    is_renting          = col_or_na(st, "is_renting"),
    is_returning        = col_or_na(st, "is_returning"),
    bikes_by_type       = types,
    stringsAsFactors = FALSE
  )

  path <- file.path(outdir, "station_status",
                    tagged(paste0("status_", day_stamp()), ".csv.gz", tag))
  append_csv(path, out, gzipped = TRUE)
  nrow(out)
}

# ---- main loop -------------------------------------------------------------

main <- function() {
  opts <- parse_args(commandArgs(trailingOnly = TRUE))
  dir.create(opts$outdir, recursive = TRUE, showWarnings = FALSE)

  endpoints <- tryCatch(discover_feeds(opts$feed), error = function(e) {
    log_msg("ERROR reading the feed: ", conditionMessage(e))
    log_msg("Feed URLs move. The authoritative catalogue is ",
            "github.com/MobilityData/gbfs/blob/master/systems.csv (filter CH).")
    quit(status = 1)
  })

  keep_ids <- write_station_information(endpoints, opts$outdir, opts$city, opts$tag)
  if (!is.null(opts$city) && length(keep_ids) == 0) {
    log_msg("No stations matched --city '", opts$city,
            "'. Drop the filter and inspect station_information.")
    quit(status = 1)
  }

  last_refresh <- day_stamp()
  polls <- 0L
  started <- Sys.time()
  if (!is.null(opts$duration)) {
    log_msg("Bounded run: will stop after ", opts$duration, " minutes.")
  }

  repeat {
    res <- tryCatch({
      if (day_stamp() != last_refresh) {
        keep_ids <<- write_station_information(endpoints, opts$outdir, opts$city, opts$tag)
        last_refresh <<- day_stamp()
      }
      poll_status(endpoints, opts$outdir, keep_ids, opts$tag)
    }, error = function(e) {
      log_msg("Poll failed (", conditionMessage(e), ") - retrying next interval.")
      NA_integer_
    })

    if (!is.na(res)) {
      polls <- polls + 1L
      log_msg("Poll ", polls, " - ", res, " stations recorded")
    }

    if (opts$once) break
    if (!is.null(opts$duration)) {
      elapsed <- as.numeric(difftime(Sys.time(), started, units = "mins"))
      if (elapsed + opts$interval / 60 >= opts$duration) {
        log_msg("Duration limit reached (", round(elapsed, 1), " min).")
        break
      }
    }
    Sys.sleep(opts$interval)
  }

  log_msg("Stopped after ", polls, " poll(s).")
}

main()
