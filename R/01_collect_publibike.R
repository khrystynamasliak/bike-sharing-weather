#!/usr/bin/env Rscript
# ============================================================================
# 01_collect_publibike.R
#
# Accumulate a station-status history from the PubliBike GBFS feed.
#
# GBFS is a real-time specification: it reports the state of the system now and
# retains no history. PubliBike publishes no trip archive. This script polls the
# live feed on a schedule and writes each snapshot to disk, building the
# historical dataset that does not otherwise exist.
#
# Usage:
#   Rscript 01_collect_publibike.R --once              # validate setup, one snapshot
#   Rscript 01_collect_publibike.R --interval 60       # run continuously
#   Rscript 01_collect_publibike.R --interval 60 --city Bern
#
#   # bounded run, for CI: poll for 5h20m then exit cleanly
#   Rscript 01_collect_publibike.R --interval 60 --duration 320 --tag $(date +%s)
#
#   # print the raw feed structure and exit (for debugging)
#   Rscript 01_collect_publibike.R --inspect
#
# --duration stops the loop after N minutes (GitHub Actions jobs are killed at
# 6 hours, so exit before that and let the next run take over).
# --tag appends a string to output filenames so each run writes its own file.
#
# IMPLEMENTATION NOTE
# All JSON is parsed with simplifyVector = FALSE, giving plain nested lists, and
# data frames are built explicitly field by field. Letting jsonlite guess at the
# shape is fragile: whether a station array becomes a data.frame or stays a list
# depends on whether every station happens to carry exactly the same fields,
# which real feeds do not guarantee. Explicit extraction works for any shape.
#
# Dependencies: jsonlite  ->  install.packages("jsonlite")
# ============================================================================

suppressPackageStartupMessages({
  if (!requireNamespace("jsonlite", quietly = TRUE)) {
    stop("This script needs jsonlite. Run:  install.packages('jsonlite')")
  }
  library(jsonlite)
})

DEFAULT_FEED <- "https://api.publibike.ch/v1/gbfs/v2/gbfs.json"
OUT_DIR      <- "data"

`%||%` <- function(a, b) if (is.null(a)) b else a

# ---- arguments -------------------------------------------------------------

parse_args <- function(args) {
  opts <- list(feed = DEFAULT_FEED, outdir = OUT_DIR, interval = 300,
               once = FALSE, city = NULL, duration = NULL, tag = NULL,
               inspect = FALSE)
  i <- 1
  while (i <= length(args)) {
    a <- args[[i]]
    if (a == "--once")            opts$once <- TRUE
    else if (a == "--inspect")    opts$inspect <- TRUE
    else if (a == "--feed")     { i <- i + 1; opts$feed <- args[[i]] }
    else if (a == "--outdir")   { i <- i + 1; opts$outdir <- args[[i]] }
    else if (a == "--interval") { i <- i + 1; opts$interval <- as.integer(args[[i]]) }
    else if (a == "--city")     { i <- i + 1; opts$city <- args[[i]] }
    else if (a == "--duration") { i <- i + 1; opts$duration <- as.numeric(args[[i]]) }
    else if (a == "--tag")      { i <- i + 1; opts$tag <- gsub("[^A-Za-z0-9_-]", "", args[[i]]) }
    else stop("Unknown argument: ", a)
    i <- i + 1
  }
  opts
}

log_msg   <- function(...) cat(format(Sys.time(), "%Y-%m-%d %H:%M:%S"), " ", ..., "\n", sep = "")
utc_now   <- function() format(Sys.time(), "%Y-%m-%dT%H:%M:%S", tz = "UTC")
day_stamp <- function() format(Sys.time(), "%Y%m%d", tz = "UTC")

tagged <- function(stem, ext, tag) {
  if (is.null(tag) || !nzchar(tag)) paste0(stem, ext) else paste0(stem, "_", tag, ext)
}

# ---- list helpers ----------------------------------------------------------
# These operate on plain nested lists, so they do not care whether the feed's
# arrays are ragged, uniform, or empty.

get_json <- function(url) jsonlite::fromJSON(url, simplifyVector = FALSE)

# Pull one field from a list of records, coercing to an atomic vector and
# substituting NA where the field is missing, empty, or itself a list.
pluck <- function(records, field, type = c("character", "numeric", "integer")) {
  type <- match.arg(type)
  empty <- switch(type, character = NA_character_, numeric = NA_real_, integer = NA_integer_)
  if (length(records) == 0) {
    return(switch(type, character = character(0), numeric = numeric(0), integer = integer(0)))
  }
  out <- vapply(records, function(r) {
    v <- r[[field]]
    if (is.null(v) || length(v) != 1 || is.list(v)) return(empty)
    switch(type,
           character = as.character(v),
           numeric   = suppressWarnings(as.numeric(v)),
           integer   = suppressWarnings(as.integer(v)))
  }, FUN.VALUE = switch(type, character = character(1),
                        numeric = numeric(1), integer = integer(1)))
  unname(out)
}

# Serialise per-vehicle-type counts to a compact JSON string, so one status
# reading stays one row. 02_derive_flows.R splits it back out.
encode_types <- function(records) {
  if (length(records) == 0) return(character(0))
  vapply(records, function(r) {
    vt <- r[["vehicle_types_available"]]
    if (is.null(vt) || length(vt) == 0 || !is.list(vt)) return("")
    ids <- vapply(vt, function(x) as.character(x[["vehicle_type_id"]] %||% ""), character(1))
    cnt <- vapply(vt, function(x) {
      v <- x[["count"]]
      if (is.null(v)) NA_integer_ else suppressWarnings(as.integer(v))
    }, integer(1))
    ok <- nzchar(ids) & !is.na(cnt)
    if (!any(ok)) return("")
    paste0("{", paste(sprintf('"%s":%d', ids[ok], cnt[ok]), collapse = ","), "}")
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

# ---- feed discovery --------------------------------------------------------

discover_feeds <- function(discovery_url) {
  doc <- get_json(discovery_url)
  d <- doc$data

  feeds <- NULL
  if (!is.null(d$feeds)) {
    feeds <- d$feeds                                    # GBFS 3.x
  } else {
    for (lang in c("en", "de", "fr", "it")) {            # GBFS 2.x
      if (!is.null(d[[lang]]) && !is.null(d[[lang]]$feeds)) { feeds <- d[[lang]]$feeds; break }
    }
    if (is.null(feeds)) for (nm in names(d)) {
      if (!is.null(d[[nm]]$feeds)) { feeds <- d[[nm]]$feeds; break }
    }
  }
  if (is.null(feeds)) {
    stop("Could not find a feed list in ", discovery_url,
         ". Top-level keys: ", paste(names(d), collapse = ", "))
  }

  nms  <- pluck(feeds, "name")
  urls <- pluck(feeds, "url")
  ok <- !is.na(nms) & !is.na(urls)
  endpoints <- setNames(urls[ok], nms[ok])

  log_msg("Discovered ", length(endpoints), " endpoints: ",
          paste(sort(names(endpoints)), collapse = ", "))

  for (req in c("station_information", "station_status")) {
    if (!req %in% names(endpoints)) {
      stop("Feed does not expose `", req, "`. Available: ",
           paste(sort(names(endpoints)), collapse = ", "))
    }
  }
  endpoints
}

# Locate the station array wherever it sits in the response.
#
# The GBFS spec says data.stations, but operators nest things differently in
# practice (under a language key, under a network key, as a named object rather
# than an array). Rather than guessing paths, walk the parsed structure and find
# any list of records that carries a station_id. That works whatever the shape.
looks_like_station <- function(x) {
  is.list(x) && !is.null(names(x)) &&
    any(c("station_id", "stationId", "id") %in% names(x))
}

find_station_array <- function(node, depth = 0) {
  if (depth > 6 || !is.list(node)) return(NULL)

  # An unnamed list whose elements look like station records.
  if (is.null(names(node)) && length(node) > 0) {
    hits <- vapply(node, looks_like_station, logical(1))
    if (all(hits)) return(node)
  }

  # A named object whose *values* look like station records (id-keyed map).
  if (!is.null(names(node)) && length(node) > 0 && !looks_like_station(node)) {
    hits <- vapply(node, looks_like_station, logical(1))
    if (length(hits) > 1 && all(hits)) return(unname(node))
  }

  # A single record on its own.
  if (looks_like_station(node) && !is.null(node[["station_id"]])) return(list(node))

  # Recurse, preferring the largest array found.
  best <- NULL
  for (child in node) {
    got <- find_station_array(child, depth + 1)
    if (!is.null(got) && (is.null(best) || length(got) > length(best))) best <- got
  }
  best
}

extract_stations <- function(doc) {
  st <- doc$data$stations                       # the spec-compliant path first
  if (!is.null(st) && is.list(st) && length(st) > 0) {
    if (!is.null(names(st)) && looks_like_station(st)) return(list(st))
    if (!is.null(names(st))) return(unname(st))
    return(st)
  }
  found <- find_station_array(doc)
  if (is.null(found)) list() else found
}

# Print enough of the response to diagnose an unexpected shape, without dumping
# megabytes into the Actions log.
dump_shape <- function(doc, label) {
  cat("\n---- raw structure of ", label, " ----\n", sep = "")
  utils::str(doc, max.level = 4, list.len = 12, give.attr = FALSE, nchar.max = 120)
  cat("---- end structure ----\n\n")
}

# ---- diagnostics -----------------------------------------------------------

inspect_feed <- function(feed_url) {
  log_msg("Inspecting ", feed_url)
  endpoints <- discover_feeds(feed_url)
  for (nm in c("station_information", "station_status")) {
    cat("\n================ ", nm, " ================\n", sep = "")
    cat("URL: ", endpoints[[nm]], "\n", sep = "")
    doc <- get_json(endpoints[[nm]])
    cat("top-level keys: ", paste(names(doc), collapse = ", "), "\n", sep = "")
    if (!is.null(doc$data)) {
      cat("data keys:      ", paste(names(doc$data), collapse = ", "), "\n", sep = "")
    }
    st <- extract_stations(doc)
    cat("records found:  ", length(st), "\n", sep = "")
    if (length(st) > 0) {
      cat("fields on record 1:\n")
      str(st[[1]], max.level = 2, give.attr = FALSE)
    }
  }
  cat("\nInspection complete.\n")
}

# ---- the two datasets ------------------------------------------------------

matches_city <- function(st, city) {
  if (is.null(city) || !nzchar(city)) return(rep(TRUE, length(st)))
  hay <- tolower(paste(pluck(st, "name"), pluck(st, "address"), pluck(st, "post_code")))
  grepl(tolower(city), hay, fixed = TRUE)
}

write_station_information <- function(endpoints, outdir, city, tag = NULL) {
  doc <- get_json(endpoints[["station_information"]])
  st  <- extract_stations(doc)
  if (length(st) == 0) {
    dump_shape(doc, "station_information")
    stop("station_information returned no records - see the structure dumped above.")
  }
  log_msg("station_information: ", length(st), " records returned by the feed")

  st <- st[matches_city(st, city)]
  if (length(st) == 0) {
    stop("No stations matched --city '", city, "'. Re-run without --city to see ",
         "the available station names.")
  }

  out <- data.frame(
    fetched_at_utc = utc_now(),
    station_id     = pluck(st, "station_id"),
    name           = pluck(st, "name"),
    lat            = pluck(st, "lat", "numeric"),
    lon            = pluck(st, "lon", "numeric"),
    capacity       = pluck(st, "capacity", "integer"),
    address        = pluck(st, "address"),
    post_code      = pluck(st, "post_code"),
    stringsAsFactors = FALSE
  )

  path <- file.path(outdir, "station_information",
                    tagged(paste0("stations_", day_stamp()), ".csv", tag))
  if (file.exists(path)) unlink(path)
  append_csv(path, out)
  log_msg("Wrote ", nrow(out), " stations to ", path)
  out$station_id
}

poll_status <- function(endpoints, outdir, keep_ids, tag = NULL) {
  doc <- get_json(endpoints[["station_status"]])
  st  <- extract_stations(doc)
  if (length(st) == 0) {
    dump_shape(doc, "station_status")
    stop("station_status returned no records - see the structure dumped above.")
  }

  sid <- pluck(st, "station_id")
  if (!is.null(keep_ids) && length(keep_ids)) {
    sel <- sid %in% keep_ids
    st  <- st[sel]
    sid <- sid[sel]
  }
  if (length(st) == 0) return(0L)

  out <- data.frame(
    polled_at_utc       = utc_now(),
    last_reported       = pluck(st, "last_reported", "numeric"),
    station_id          = sid,
    num_bikes_available = pluck(st, "num_bikes_available", "integer"),
    num_docks_available = pluck(st, "num_docks_available", "integer"),
    num_bikes_disabled  = pluck(st, "num_bikes_disabled", "integer"),
    is_installed        = pluck(st, "is_installed", "integer"),
    is_renting          = pluck(st, "is_renting", "integer"),
    is_returning        = pluck(st, "is_returning", "integer"),
    bikes_by_type       = encode_types(st),
    stringsAsFactors = FALSE
  )

  path <- file.path(outdir, "station_status",
                    tagged(paste0("status_", day_stamp()), ".csv.gz", tag))
  append_csv(path, out, gzipped = TRUE)
  nrow(out)
}

# ---- main ------------------------------------------------------------------

main <- function() {
  opts <- parse_args(commandArgs(trailingOnly = TRUE))

  if (opts$inspect) {
    inspect_feed(opts$feed)
    return(invisible(NULL))
  }

  dir.create(opts$outdir, recursive = TRUE, showWarnings = FALSE)

  endpoints <- tryCatch(discover_feeds(opts$feed), error = function(e) {
    log_msg("ERROR reading the feed: ", conditionMessage(e))
    log_msg("Run with --inspect to dump the raw structure. Feed URLs also move; ",
            "see github.com/MobilityData/gbfs/blob/master/systems.csv (filter CH).")
    quit(status = 1)
  })

  keep_ids <- tryCatch(
    write_station_information(endpoints, opts$outdir, opts$city, opts$tag),
    error = function(e) { log_msg("ERROR: ", conditionMessage(e)); quit(status = 1) })

  last_refresh <- day_stamp()
  polls <- 0L
  started <- Sys.time()
  if (!is.null(opts$duration)) {
    log_msg("Bounded run: stopping after ", opts$duration, " minutes.")
  }

  repeat {
    res <- tryCatch({
      if (day_stamp() != last_refresh) {
        keep_ids <- write_station_information(endpoints, opts$outdir, opts$city, opts$tag)
        last_refresh <- day_stamp()
      }
      poll_status(endpoints, opts$outdir, keep_ids, opts$tag)
    }, error = function(e) {
      log_msg("Poll failed (", conditionMessage(e), ") - retrying next interval.")
      NA_integer_
    })

    if (!is.na(res)) {
      polls <- polls + 1L
      if (polls <= 3L || polls %% 10L == 0L) {
        log_msg("Poll ", polls, " - ", res, " stations recorded")
      }
    }

    if (opts$once) break
    if (!is.null(opts$duration)) {
      elapsed <- as.numeric(difftime(Sys.time(), started, units = "mins"))
      if (elapsed + opts$interval / 60 >= opts$duration) {
        log_msg("Duration limit reached (", round(elapsed, 1), " min, ", polls, " polls).")
        break
      }
    }
    Sys.sleep(opts$interval)
  }

  log_msg("Stopped after ", polls, " poll(s).")
}

main()
