#!/usr/bin/env Rscript
# ============================================================================
# 01_collect_publibike.R
#
# Accumulate a station-status history from the PubliBike / Velospot GBFS feed.
#
# GBFS is a real-time specification: it reports the state of the system now and
# retains no history. PubliBike publishes no trip archive. This script polls the
# live feed on a schedule and writes each snapshot to disk, building the
# historical dataset that does not otherwise exist.
#
# Usage:
#   Rscript 01_collect_publibike.R --probe                    # measure the feed, write nothing
#   Rscript 01_collect_publibike.R --once --city Bern         # validate setup, one snapshot
#   Rscript 01_collect_publibike.R --city Bern --interval 30  # run continuously
#
#   # bounded run, for CI: poll for 5h20m then exit cleanly
#   Rscript 01_collect_publibike.R --city Bern --duration 320 --tag $(date -u +%Y%m%dT%H%M%SZ)
#
#   # print the raw feed structure and exit (for debugging)
#   Rscript 01_collect_publibike.R --inspect
#
# --duration stops the loop after N minutes (GitHub Actions jobs are killed at
# 6 hours, so exit before that and let the next run take over).
# --tag appends a string to output filenames so each run writes its own file.
#
# ----------------------------------------------------------------------------
# WHAT THIS FEED ACTUALLY DOES, AND WHY THE COLLECTOR IS SHAPED THIS WAY
#
# Measured against api.mobidata-bw.de/sharing/gbfs/v3/velospot_ch on 25 Aug 2026:
#
#  1. It advertises `ttl: 60`, which is not remotely true. Snapshot timestamps
#     land on the quarter hour (:15:05, :30:05, :45:05), so something upstream
#     runs every 15 minutes - but what actually REACHES the API is far sparser
#     and quite irregular. Over 110 polls across 38 minutes, only three distinct
#     snapshots were ever served, and one 75-minute stretch produced no new
#     snapshot at all. Polling every 60 s fetched the same bytes 15 times over.
#
#     Treat ~15 minutes as a best case and expect worse. Run --probe over an
#     hour or more to see what the feed is doing today; a single short probe
#     will mislead you, as the first one here did.
#
#  2. It is served by several replicas whose caches are NOT in step, and the
#     spread is large: snapshots 90 minutes apart were served interchangeably
#     within one window, individual responses up to 96 minutes stale. Recording
#     that stream in arrival order would invent a departure and a matching
#     arrival at every station that moved in between.
#
#     The fix is to key on snapshot IDENTITY, not recency - see
#     DEDUPE_BY_SNAPSHOT below. Each distinct `last_updated` is stored once,
#     whenever it turns up, and 02_derive_flows sorts by it before differencing.
#     Rejecting merely-older responses would instead discard real history.
#
#  3. It supports conditional GET. Sending the last few ETags in If-None-Match
#     turns an unchanged poll into a 304 with an empty body, so frequent polling
#     costs almost no bandwidth. Multi-value If-None-Match is honoured, which
#     matters because of (2): holding several ETags keeps every replica quiet.
#
#  4. Each station carries its own `last_reported`, at second resolution, which
#     is when THAT STATION last changed. This is the one piece of precision the
#     feed does give you: the publication cadence limits how promptly a change
#     is seen, not how precisely it can be timestamped. 02_derive_flows.R keys
#     off it.
#
#  5. `num_docks_available` and `num_bikes_disabled` are absent. Every station
#     is `is_virtual_station: true`, so `capacity` is a nominal allowance rather
#     than a count of physical docks. Occupancy is measurable; dock saturation
#     is not.
#
# Re-run with --probe to confirm these still hold before trusting them.
# ----------------------------------------------------------------------------
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

# PubliBike merged with Velospot; the old api.publibike.ch feed still responds
# but returns an empty station list (verified 25 Aug 2026). The live stations
# are in the Velospot feed republished by MobiData BW.
DEFAULT_FEED <- "https://api.mobidata-bw.de/sharing/gbfs/v3/velospot_ch/gbfs"
OUT_DIR      <- "data"

# Reject a response whose station count has collapsed relative to the best seen
# so far. A truncated reply that is written as though complete looks exactly
# like a network-wide outage in the derived data.
MIN_COUNT_RATIO <- 0.5

# Record each distinct published snapshot exactly once. See note (2) above.
#
# The obvious rule - "accept only snapshots newer than the newest so far" - is
# wrong here, and measurably so. Because the replicas hold DIFFERENT snapshots,
# an older-looking response is often one this run has never recorded, and
# discarding it throws away real history: in a 22-minute test the collector
# rejected 06:30:05 as stale, having stored 06:15:05 and 07:45:05 but never
# 06:30:05 itself.
#
# Keying on identity instead of recency collects every snapshot the load
# balancer routes us to. Arrival order does not matter, because 02_derive_flows
# sorts by feed_last_updated before differencing and de-duplicates on
# (station_id, observed_at) - so the series it works from is chronological
# whatever order the parts turned up in.
DEDUPE_BY_SNAPSHOT <- TRUE

# How many recent ETags to offer in If-None-Match. Needs to cover the number of
# out-of-step replicas; 6 is comfortably above the 2 observed.
ETAG_MEMORY <- 6

# City centres, for --city. Scoping by distance from a point is reproducible and
# defensible; substring-matching station names is not. "Bern" appears in
# `Bernoullistrasse 30 - Basel` and `Berninaplatz - Zürich`, so the old
# name-matching filter pulled in 325 stations from three different cities.
CITY_CENTRES <- list(
  "bern"              = c(46.9480, 7.4474),
  "zurich"            = c(47.3769, 8.5417),
  "zürich"            = c(47.3769, 8.5417),
  "basel"             = c(47.5596, 7.5886),
  "fribourg"          = c(46.8065, 7.1619),
  "biel"              = c(47.1368, 7.2467),
  "bienne"            = c(47.1368, 7.2467),
  "lugano"            = c(46.0037, 8.9511),
  "sion"              = c(46.2331, 7.3606),
  "aarau"             = c(47.3925, 8.0442),
  "martigny"          = c(46.1177, 7.0930),
  "la chaux-de-fonds" = c(47.1000, 6.8250)
)
DEFAULT_RADIUS_KM <- 5

`%||%` <- function(a, b) if (is.null(a)) b else a

# ---- arguments -------------------------------------------------------------

parse_args <- function(args) {
  opts <- list(feed = DEFAULT_FEED, outdir = OUT_DIR, interval = 30,
               once = FALSE, city = NULL, centre = NULL, radius = NULL,
               all = FALSE, duration = NULL, tag = NULL, inspect = FALSE,
               probe = FALSE, probe_minutes = 20, station_refresh_hours = 6,
               timeout = 45, retries = 3)
  i <- 1
  while (i <= length(args)) {
    a <- args[[i]]
    if (a == "--once")             opts$once <- TRUE
    else if (a == "--inspect")     opts$inspect <- TRUE
    else if (a == "--probe")       opts$probe <- TRUE
    else if (a == "--all")         opts$all <- TRUE
    else if (a == "--feed")      { i <- i + 1; opts$feed <- args[[i]] }
    else if (a == "--outdir")    { i <- i + 1; opts$outdir <- args[[i]] }
    else if (a == "--interval")  { i <- i + 1; opts$interval <- as.numeric(args[[i]]) }
    else if (a == "--city")      { i <- i + 1; opts$city <- args[[i]] }
    else if (a == "--centre")    { i <- i + 1; opts$centre <- args[[i]] }
    else if (a == "--center")    { i <- i + 1; opts$centre <- args[[i]] }
    else if (a == "--radius")    { i <- i + 1; opts$radius <- as.numeric(args[[i]]) }
    else if (a == "--duration")  { i <- i + 1; opts$duration <- as.numeric(args[[i]]) }
    else if (a == "--probe-minutes") { i <- i + 1; opts$probe_minutes <- as.numeric(args[[i]]) }
    else if (a == "--station-refresh-hours") { i <- i + 1; opts$station_refresh_hours <- as.numeric(args[[i]]) }
    else if (a == "--timeout")   { i <- i + 1; opts$timeout <- as.numeric(args[[i]]) }
    else if (a == "--tag")       { i <- i + 1; opts$tag <- gsub("[^A-Za-z0-9_-]", "", args[[i]]) }
    else stop("Unknown argument: ", a)
    i <- i + 1
  }

  # An empty --city (the workflow passes '' for "whole network") means --all.
  if (!is.null(opts$city) && !nzchar(trimws(opts$city))) opts$city <- NULL
  if (is.null(opts$city) && is.null(opts$centre)) opts$all <- TRUE
  if (is.null(opts$radius)) opts$radius <- DEFAULT_RADIUS_KM
  opts
}

log_msg   <- function(...) cat(format(Sys.time(), "%Y-%m-%d %H:%M:%S"), " ", ..., "\n", sep = "")
utc_now   <- function() format(Sys.time(), "%Y-%m-%dT%H:%M:%S", tz = "UTC")
day_stamp <- function() format(Sys.time(), "%Y%m%d", tz = "UTC")

tagged <- function(stem, ext, tag) {
  if (is.null(tag) || !nzchar(tag)) paste0(stem, ext) else paste0(stem, "_", tag, ext)
}

# ---- time ------------------------------------------------------------------

# GBFS 2.x timestamps are POSIX integers; 3.0 uses RFC3339 strings such as
# "2026-08-25T06:30:05.000+00:00". R's %z wants "+0000", so the colon in the
# offset is removed before parsing. Returns seconds since epoch.
iso_to_epoch <- function(x) {
  if (is.null(x)) return(NA_real_)
  if (is.numeric(x)) return(as.numeric(x))
  s <- trimws(as.character(x))
  s[!nzchar(s)] <- NA_character_
  s <- sub("\\.[0-9]+", "", s)                          # strip fractional seconds
  s <- sub("([+-][0-9]{2}):([0-9]{2})$", "\\1\\2", s)    # +00:00 -> +0000
  s <- sub("Z$", "+0000", s)
  out <- suppressWarnings(as.numeric(as.POSIXct(s, format = "%Y-%m-%dT%H:%M:%S%z", tz = "UTC")))
  bad <- is.na(out) & !is.na(s)
  if (any(bad)) {
    out[bad] <- suppressWarnings(as.numeric(
      as.POSIXct(s[bad], format = "%Y-%m-%dT%H:%M:%S", tz = "UTC")))
  }
  # A bare number arriving as a string (GBFS 2.x served as JSON string).
  bad <- is.na(out) & !is.na(s) & grepl("^[0-9]+$", s)
  if (any(bad)) out[bad] <- as.numeric(s[bad])
  out
}

epoch_to_iso <- function(e) {
  ifelse(is.na(e), NA_character_,
         format(as.POSIXct(e, origin = "1970-01-01", tz = "UTC"),
                "%Y-%m-%dT%H:%M:%S", tz = "UTC"))
}

# ---- HTTP ------------------------------------------------------------------
# The curl binary is used rather than base R's url() because this needs three
# things base R will not give: a hard timeout, transparent gzip (27 KB on the
# wire instead of 634 KB), and conditional GET. Falls back to download.file()
# where curl is unavailable, losing only the 304 optimisation.

CURL_BIN <- Sys.which("curl")

etag_from_headers <- function(path) {
  if (!file.exists(path)) return(NA_character_)
  ln <- readLines(path, warn = FALSE)
  ln <- grep("^etag:", ln, ignore.case = TRUE, value = TRUE)
  if (!length(ln)) return(NA_character_)
  trimws(sub("(?i)^etag:", "", ln[length(ln)], perl = TRUE))
}

# Returns list(status = integer, path = file or NA, etag = character or NA).
# status 304 means "unchanged, nothing downloaded"; 0 means the request failed.
http_get <- function(url, etags = character(0), timeout = 45, retries = 3) {
  body <- tempfile(fileext = ".json")
  hdr  <- tempfile(fileext = ".hdr")

  if (!nzchar(CURL_BIN)) {
    ok <- tryCatch({
      utils::download.file(url, body, quiet = TRUE, mode = "wb",
                           method = "libcurl")
      TRUE
    }, error = function(e) FALSE, warning = function(w) FALSE)
    return(list(status = if (ok) 200L else 0L,
                path = if (ok) body else NA_character_, etag = NA_character_))
  }

  args <- c("-sS", "--compressed",
            "--max-time", format(timeout),
            "--retry", format(retries), "--retry-delay", "2",
            "--retry-connrefused",
            "-D", shQuote(hdr), "-o", shQuote(body),
            "-w", shQuote("%{http_code}"))
  etags <- etags[!is.na(etags) & nzchar(etags)]
  if (length(etags)) {
    args <- c(args, "-H",
              shQuote(paste0("If-None-Match: ", paste(etags, collapse = ", "))))
  }
  args <- c(args, shQuote(url))

  code <- suppressWarnings(
    tryCatch(system2(CURL_BIN, args, stdout = TRUE, stderr = ""),
             error = function(e) character(0)))
  status <- suppressWarnings(as.integer(tail(code, 1)))
  if (length(status) == 0 || is.na(status)) status <- 0L

  list(status = status,
       path   = if (status == 200L && file.exists(body) && file.size(body) > 0) body else NA_character_,
       etag   = etag_from_headers(hdr))
}

get_json <- function(url, timeout = 45, retries = 3) {
  r <- http_get(url, timeout = timeout, retries = retries)
  if (r$status != 200L || is.na(r$path)) {
    stop("HTTP ", r$status, " fetching ", url)
  }
  on.exit(unlink(r$path), add = TRUE)
  jsonlite::fromJSON(r$path, simplifyVector = FALSE)
}

# ---- list helpers ----------------------------------------------------------
# These operate on plain nested lists, so they do not care whether the feed's
# arrays are ragged, uniform, or empty.

# Pull one field from a list of records, coercing to an atomic vector and
# substituting NA where the field is missing, empty, or itself a list.
#
# `field` may be several candidate names, tried in order. This matters because
# GBFS 3.0 renamed things: num_bikes_available became num_vehicles_available,
# and free-text names became arrays of {text, language} objects.
first_scalar <- function(v) {
  if (is.null(v)) return(NULL)
  # GBFS 3.0 localised string: [{"text":"Bern Bahnhof","language":"de"}]
  if (is.list(v) && length(v) > 0 && is.list(v[[1]]) && !is.null(v[[1]][["text"]])) {
    return(v[[1]][["text"]])
  }
  if (is.list(v) || length(v) != 1) return(NULL)
  v
}

pluck <- function(records, field, type = c("character", "numeric", "integer")) {
  type <- match.arg(type)
  empty <- switch(type, character = NA_character_, numeric = NA_real_, integer = NA_integer_)
  if (length(records) == 0) {
    return(switch(type, character = character(0), numeric = numeric(0), integer = integer(0)))
  }
  out <- vapply(records, function(r) {
    v <- NULL
    for (f in field) {
      v <- first_scalar(r[[f]])
      if (!is.null(v)) break
    }
    if (is.null(v)) return(empty)
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

# The rows are formatted by hand and written with useBytes = TRUE rather than
# handed to write.table. Station names carry umlauts and accents
# (Schanzenbrücke, Charrière) which jsonlite correctly flags as UTF-8; under a
# non-UTF-8 locale - which is what a bare shell gives you, and sometimes a CI
# runner - write.table re-encodes those to "<U+00FC>" escapes, silently
# corrupting every name in the dimension table. Passing the bytes through
# unchanged keeps the file UTF-8 whatever the locale happens to be.
#
# The output is byte-identical to write.table(sep=",", qmethod="double"):
# quoted header and character fields, bare numerics, unquoted NA.
csv_field <- function(x) {
  if (is.character(x)) {
    ifelse(is.na(x), "NA", paste0('"', gsub('"', '""', x, useBytes = TRUE), '"'))
  } else if (is.logical(x)) {
    ifelse(is.na(x), "NA", ifelse(x, "TRUE", "FALSE"))
  } else {
    ifelse(is.na(x), "NA", as.character(x))
  }
}

append_csv <- function(path, df, gzipped = FALSE) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  is_new <- !file.exists(path)
  con <- if (gzipped) gzfile(path, open = "at") else file(path, open = "at")
  on.exit(close(con))
  rows <- do.call(paste, c(lapply(df, csv_field), sep = ","))
  if (is_new) rows <- c(paste0('"', names(df), '"', collapse = ","), rows)
  writeLines(rows, con, useBytes = TRUE)
}

# ---- geography -------------------------------------------------------------

haversine_km <- function(lat1, lon1, lat2, lon2) {
  r <- 6371
  p1 <- lat1 * pi / 180; p2 <- lat2 * pi / 180
  dp <- (lat2 - lat1) * pi / 180
  dl <- (lon2 - lon1) * pi / 180
  a <- sin(dp / 2)^2 + cos(p1) * cos(p2) * sin(dl / 2)^2
  2 * r * asin(pmin(1, sqrt(a)))
}

resolve_centre <- function(opts) {
  if (opts$all) return(NULL)
  if (!is.null(opts$centre)) {
    parts <- suppressWarnings(as.numeric(strsplit(trimws(opts$centre), "[, ]+")[[1]]))
    parts <- parts[!is.na(parts)]
    if (length(parts) != 2) {
      stop("--centre expects 'lat,lon', e.g. --centre 46.9480,7.4474")
    }
    return(list(lat = parts[1], lon = parts[2], label = opts$centre))
  }
  key <- tolower(trimws(opts$city))
  if (!key %in% names(CITY_CENTRES)) {
    stop("Unknown --city '", opts$city, "'. Known: ",
         paste(sort(unique(names(CITY_CENTRES))), collapse = ", "),
         ". Or give --centre lat,lon.")
  }
  c2 <- CITY_CENTRES[[key]]
  list(lat = c2[1], lon = c2[2], label = opts$city)
}

# ---- feed discovery --------------------------------------------------------

discover_feeds <- function(discovery_url, timeout = 45) {
  doc <- get_json(discovery_url, timeout = timeout)
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

inspect_feed <- function(feed_url, timeout) {
  log_msg("Inspecting ", feed_url)
  endpoints <- discover_feeds(feed_url, timeout)
  for (nm in c("station_information", "station_status")) {
    cat("\n================ ", nm, " ================\n", sep = "")
    cat("URL: ", endpoints[[nm]], "\n", sep = "")
    doc <- get_json(endpoints[[nm]], timeout = timeout)
    cat("top-level keys: ", paste(names(doc), collapse = ", "), "\n", sep = "")
    cat("last_updated:   ", as.character(doc$last_updated %||% "(none)"),
        "   ttl: ", as.character(doc$ttl %||% "(none)"), "\n", sep = "")
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

# Measure how often the feed really publishes, and how much of the network is
# reporting, without writing any data. Run this before committing days of
# collection to a sampling interval.
probe_feed <- function(endpoints, opts) {
  cat("\n", strrep("=", 68), "\n", sep = "")
  cat("FEED PROBE - ", opts$probe_minutes, " minutes at ", opts$interval,
      "s, writing nothing\n", sep = "")
  cat(strrep("=", 68), "\n", sep = "")

  url <- endpoints[["station_status"]]
  etags <- character(0)
  seen_lu <- numeric(0)
  n_probe <- 0L; n_304 <- 0L; n_new <- 0L; n_stale <- 0L; n_err <- 0L
  started <- Sys.time()
  tick <- 0L

  repeat {
    r <- http_get(url, etags, opts$timeout, opts$retries)
    n_probe <- n_probe + 1L
    if (!is.na(r$etag)) etags <- head(unique(c(r$etag, etags)), ETAG_MEMORY)

    if (r$status == 304L) {
      n_304 <- n_304 + 1L
    } else if (r$status == 200L && !is.na(r$path)) {
      doc <- tryCatch(jsonlite::fromJSON(r$path, simplifyVector = FALSE),
                      error = function(e) NULL)
      unlink(r$path)
      if (is.null(doc)) { n_err <- n_err + 1L } else {
        lu <- iso_to_epoch(doc$last_updated)
        if (!is.na(lu) && lu %in% seen_lu) {
          n_stale <- n_stale + 1L
          log_msg("  replica re-served a snapshot already seen: ", epoch_to_iso(lu),
                  "  (", round((as.numeric(Sys.time()) - lu) / 60), " min old)")
        } else {
          n_new <- n_new + 1L
          seen_lu <- c(seen_lu, lu)
          log_msg("  new snapshot published: ", epoch_to_iso(lu),
                  "  (", length(extract_stations(doc)), " stations)")
        }
      }
    } else {
      n_err <- n_err + 1L
      log_msg("  HTTP ", r$status)
    }

    tick <- tick + 1L
    elapsed <- as.numeric(difftime(Sys.time(), started, units = "mins"))
    if (elapsed + opts$interval / 60 > opts$probe_minutes) break
    sleep_to_tick(started, tick, opts$interval)
  }

  cat("\n--- results ---\n")
  cat(sprintf("polls:               %d over %.1f minutes\n", n_probe,
              as.numeric(difftime(Sys.time(), started, units = "mins"))))
  cat(sprintf("  304 not modified:  %d\n", n_304))
  cat(sprintf("  new snapshots:     %d\n", n_new))
  cat(sprintf("  already seen:      %d%s\n", n_stale,
              if (n_stale > 0) "   <- replicas re-serving old snapshots" else ""))
  cat(sprintf("  errors:            %d\n", n_err))

  if (length(seen_lu) >= 2) {
    d <- diff(sort(seen_lu)) / 60
    cat(sprintf("\npublication interval: median %.1f min (min %.1f, max %.1f)\n",
                median(d), min(d), max(d)))
    cat(sprintf("Polling faster than ~%.0f min gains nothing but promptness.\n",
                median(d)))
  } else {
    cat("\nFewer than 2 new snapshots seen - run --probe with a longer",
        "--probe-minutes to measure the publication interval.\n")
  }
  invisible(NULL)
}

# ---- the two datasets ------------------------------------------------------

# Returns the ids to keep, or NULL for "everything".
select_stations <- function(st, centre, radius_km) {
  if (is.null(centre)) return(NULL)
  lat <- pluck(st, "lat", "numeric")
  lon <- pluck(st, "lon", "numeric")
  d <- haversine_km(centre$lat, centre$lon, lat, lon)
  keep <- !is.na(d) & d <= radius_km
  log_msg("Scope: ", sum(keep), " of ", length(st), " stations within ",
          radius_km, " km of ", centre$label,
          " (", sprintf("%.4f, %.4f", centre$lat, centre$lon), ")")
  if (!any(keep)) {
    stop("No stations within ", radius_km, " km of ", centre$label,
         ". Widen --radius, or check the centre coordinates.")
  }
  keep
}

# state carries n_seen_max so a truncated reply can be recognised.
write_station_information <- function(endpoints, opts, centre, state) {
  doc <- get_json(endpoints[["station_information"]], opts$timeout, opts$retries)
  st  <- extract_stations(doc)
  if (length(st) == 0) {
    dump_shape(doc, "station_information")
    stop("station_information returned no records - see the structure dumped above.")
  }

  if (length(st) < MIN_COUNT_RATIO * state$si_max) {
    log_msg("REJECTED station_information: ", length(st), " records, but ",
            state$si_max, " seen earlier this run. Keeping the previous set.")
    # Stamp the attempt anyway, so a persistently truncated dimension endpoint
    # is retried on the normal schedule rather than on every single poll.
    state$si_at <- Sys.time()
    return(state)
  }
  state$si_max <- max(state$si_max, length(st))
  log_msg("station_information: ", length(st), " records returned by the feed")

  keep <- select_stations(st, centre, opts$radius)
  if (!is.null(keep)) st <- st[keep]

  out <- data.frame(
    fetched_at_utc = utc_now(),
    station_id     = pluck(st, c("station_id", "id")),
    name           = pluck(st, c("name", "station_name")),
    lat            = pluck(st, "lat", "numeric"),
    lon            = pluck(st, "lon", "numeric"),
    capacity       = pluck(st, c("capacity", "num_docks"), "integer"),
    address        = pluck(st, c("address", "cross_street")),
    post_code      = pluck(st, c("post_code", "postal_code")),
    region_id      = pluck(st, "region_id"),
    stringsAsFactors = FALSE
  )

  path <- file.path(opts$outdir, "station_information",
                    tagged(paste0("stations_", day_stamp()), ".csv", opts$tag))
  append_csv(path, out)
  log_msg("Wrote ", nrow(out), " stations to ", path)

  state$keep_ids <- out$station_id
  state$si_at    <- Sys.time()
  state
}

# One conditional poll. Writes at most one snapshot; always appends one row to
# the poll log so downtime is measurable rather than inferred.
poll_once <- function(endpoints, opts, state) {
  r <- http_get(endpoints[["station_status"]], state$etags, opts$timeout, opts$retries)
  probe_at <- utc_now()
  if (!is.na(r$etag)) {
    state$etags <- head(unique(c(r$etag, state$etags)), ETAG_MEMORY)
  }

  finish <- function(action, n = NA_integer_, lu = NA_real_) {
    append_csv(file.path(opts$outdir, "poll_log",
                         tagged(paste0("polls_", day_stamp()), ".csv", opts$tag)),
               data.frame(probe_at_utc = probe_at, http_status = r$status,
                          action = action, n_records = n,
                          feed_last_updated = epoch_to_iso(lu),
                          stringsAsFactors = FALSE))
    state$last_action <- action
    state
  }

  if (r$status == 304L)               return(finish("unchanged"))
  if (r$status != 200L || is.na(r$path)) return(finish("error"))

  doc <- tryCatch(jsonlite::fromJSON(r$path, simplifyVector = FALSE),
                  error = function(e) NULL)
  body_md5 <- unname(tools::md5sum(r$path))
  unlink(r$path)
  if (is.null(doc)) return(finish("parse_error"))

  lu <- iso_to_epoch(doc$last_updated)
  if (DEDUPE_BY_SNAPSHOT && !is.na(lu) && lu %in% state$seen_lu) {
    # Already recorded. Writing it again would duplicate every station's reading
    # for that instant, and differencing a duplicated series double-counts.
    return(finish("already_recorded", lu = lu))
  }
  # Fallback for a feed that publishes no last_updated, or a server that sends
  # no ETag: if the bytes are identical to the last snapshot taken, nothing has
  # changed and writing the row again would only create a duplicate.
  if (is.na(lu) && !is.na(body_md5) && identical(body_md5, state$last_md5)) {
    return(finish("unchanged"))
  }

  st <- extract_stations(doc)
  if (length(st) == 0) {
    dump_shape(doc, "station_status")
    return(finish("empty", 0L, lu))
  }
  if (length(st) < MIN_COUNT_RATIO * state$ss_max) {
    log_msg("REJECTED status: ", length(st), " records, but ", state$ss_max,
            " seen earlier this run.")
    return(finish("truncated", length(st), lu))
  }
  state$ss_max <- max(state$ss_max, length(st))

  sid <- pluck(st, c("station_id", "id"))
  if (!is.null(state$keep_ids) && length(state$keep_ids)) {
    sel <- sid %in% state$keep_ids
    st  <- st[sel]
    sid <- sid[sel]
  }
  if (length(st) == 0) return(finish("no_stations_in_scope", 0L, lu))

  out <- data.frame(
    polled_at_utc       = probe_at,
    feed_last_updated   = epoch_to_iso(lu),
    last_reported       = epoch_to_iso(iso_to_epoch(pluck(st, c("last_reported", "last_updated")))),
    station_id          = sid,
    num_bikes_available = pluck(st, c("num_bikes_available", "num_vehicles_available"), "integer"),
    num_docks_available = pluck(st, c("num_docks_available", "num_vehicle_docks_available"), "integer"),
    num_bikes_disabled  = pluck(st, c("num_bikes_disabled", "num_vehicles_disabled"), "integer"),
    is_installed        = pluck(st, "is_installed", "integer"),
    is_renting          = pluck(st, "is_renting", "integer"),
    is_returning        = pluck(st, "is_returning", "integer"),
    bikes_by_type       = encode_types(st),
    stringsAsFactors = FALSE
  )

  append_csv(file.path(opts$outdir, "station_status",
                       tagged(paste0("status_", day_stamp()), ".csv.gz", opts$tag)),
             out, gzipped = TRUE)

  if (!is.na(lu)) {
    state$seen_lu <- c(state$seen_lu, lu)
    state$last_lu <- if (is.na(state$last_lu)) lu else max(state$last_lu, lu)
  }
  state$last_md5 <- body_md5
  state$written <- state$written + 1L
  state$rows    <- state$rows + nrow(out)
  finish("written", nrow(out), lu)
}

# ---- scheduling ------------------------------------------------------------
# Sleeping for `interval` after the work is done makes the true cadence
# interval + fetch time, and the drift accumulates over a 5-hour run. Sleep
# until the next absolute tick instead, and skip ticks already missed.

sleep_to_tick <- function(started, tick, interval) {
  target <- as.numeric(started) + tick * interval
  wait <- target - as.numeric(Sys.time())
  if (wait > 0) Sys.sleep(wait)
  invisible(NULL)
}

# ---- main ------------------------------------------------------------------

main <- function() {
  opts <- parse_args(commandArgs(trailingOnly = TRUE))

  if (!nzchar(CURL_BIN)) {
    log_msg("NOTE: no curl binary found. Falling back to download.file(); ",
            "conditional GET is disabled, so every poll downloads in full.")
  }

  if (opts$inspect) {
    inspect_feed(opts$feed, opts$timeout)
    return(invisible(NULL))
  }

  centre <- resolve_centre(opts)
  if (is.null(centre)) {
    log_msg("Scope: the WHOLE network (no --city or --centre given).")
  }

  endpoints <- tryCatch(discover_feeds(opts$feed, opts$timeout), error = function(e) {
    log_msg("ERROR reading the feed: ", conditionMessage(e))
    log_msg("Run with --inspect to dump the raw structure. Feed URLs also move; ",
            "see github.com/MobilityData/gbfs/blob/master/systems.csv (filter CH).")
    quit(status = 1)
  })

  if (opts$probe) {
    probe_feed(endpoints, opts)
    return(invisible(NULL))
  }

  dir.create(opts$outdir, recursive = TRUE, showWarnings = FALSE)

  state <- list(keep_ids = NULL, etags = character(0), last_lu = NA_real_,
                seen_lu = numeric(0), last_md5 = NA_character_,
                si_max = 0L, ss_max = 0L, si_at = NULL,
                written = 0L, rows = 0L, last_action = NA_character_)

  state <- tryCatch(write_station_information(endpoints, opts, centre, state),
                    error = function(e) {
                      log_msg("ERROR: ", conditionMessage(e)); quit(status = 1)
                    })

  started <- Sys.time()
  tick <- 0L
  polls <- 0L
  actions <- character(0)
  if (!is.null(opts$duration)) {
    log_msg("Bounded run: stopping after ", opts$duration, " minutes.")
  }
  log_msg("Polling every ", opts$interval, "s; a snapshot is written only when ",
          "the feed's last_updated advances.")

  repeat {
    state <- tryCatch({
      if (!is.null(state$si_at) &&
          as.numeric(difftime(Sys.time(), state$si_at, units = "hours")) >=
            opts$station_refresh_hours) {
        state <- write_station_information(endpoints, opts, centre, state)
      }
      poll_once(endpoints, opts, state)
    }, error = function(e) {
      log_msg("Poll failed (", conditionMessage(e), ") - retrying next interval.")
      state$last_action <- "error"
      state
    })

    polls <- polls + 1L
    actions <- c(actions, state$last_action)
    if (identical(state$last_action, "written")) {
      log_msg("Snapshot ", state$written, " written (", state$rows,
              " rows so far, ", length(state$seen_lu), " distinct snapshots held)")
    } else if (polls %% 40L == 0L) {
      log_msg("Poll ", polls, " - ", state$written, " snapshots written; ",
              "last action: ", state$last_action)
    }

    if (opts$once) break
    tick <- tick + 1L
    if (!is.null(opts$duration)) {
      elapsed <- as.numeric(difftime(Sys.time(), started, units = "mins"))
      if (elapsed + opts$interval / 60 >= opts$duration) {
        log_msg("Duration limit reached (", round(elapsed, 1), " min).")
        break
      }
    }
    sleep_to_tick(started, tick, opts$interval)
  }

  tab <- table(actions)
  cat("\n--- run summary ---\n")
  cat(sprintf("polls:     %d over %.1f minutes\n", polls,
              as.numeric(difftime(Sys.time(), started, units = "mins"))))
  for (nm in names(tab)) cat(sprintf("  %-22s %d\n", nm, tab[[nm]]))
  cat(sprintf("snapshots written: %d  (%s status rows)\n",
              state$written, format(state$rows, big.mark = ",")))
  if (state$written == 0L && polls > 2L) {
    cat("\nWARNING: nothing was written. Either the run was shorter than the\n")
    cat("feed's publication interval, or every response was a stale replica.\n")
    cat("Run with --probe to measure the feed before collecting further.\n")
  }
}

main()
