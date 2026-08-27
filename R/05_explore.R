#!/usr/bin/env Rscript
# ============================================================================
# 05_explore.R
#
# Exploratory analysis of the joined data, and the figures for the writeup.
#
# Reads what 02/03/04 produced and answers, as far as the data currently
# allows, the questions in docs/PROPOSAL.md:
#
#   Q1  How much does rainfall suppress ridership?
#   Q2  Is the temperature relationship non-linear?
#   Q3  Are e-bike users less weather-sensitive than classic-bike users?
#   Q4  Does weather change WHERE people ride, not only how much?
#
# It prints a report to the console and writes PNG figures to figures/.
# Everything it prints is meant to be quotable in a methods section: counts,
# medians, sample sizes, and the caveat attached to each.
#
# Usage:
#   Rscript 05_explore.R
#   Rscript 05_explore.R --derived derived --out figures
#   Rscript 05_explore.R --min-hours 48        # refuse to model on less
#
# Dependencies: base R only. Figures use base graphics deliberately - no
# ggplot2, so this runs anywhere the collector does.
# ============================================================================

# Station names carry umlauts and accents. Under a non-UTF-8 locale R writes
# them as "<U+00FC>" escapes; ask for UTF-8 before anything is written.
local({
  if (isTRUE(l10n_info()[["UTF-8"]])) return(invisible(NULL))
  for (loc in c("C.UTF-8", "en_US.UTF-8", "de_CH.UTF-8", "UTF-8")) {
    if (nzchar(suppressWarnings(Sys.setlocale("LC_CTYPE", loc)))) break
  }
})

# The bike and weather files are timestamped UTC. Bern is UTC+1 or UTC+2
# depending on the season, so every human-facing hour goes through this.
# Do NOT hard-code +2: the collection window may cross the October change.
TZ <- "Europe/Zurich"

# Rain threshold. MeteoSwiss records trace amounts; 0.1 mm is the conventional
# floor for "it rained in this hour".
WET_MM <- 0.1

# Commute hours, LOCAL time. Used for the within-commute comparison that
# controls for the daily cycle without needing a full model.
COMMUTE <- c(7, 8, 17, 18)

parse_args <- function(args) {
  opts <- list(derived = "derived", out = "figures", min_hours = 72)
  i <- 1
  while (i <= length(args)) {
    a <- args[[i]]
    if (a == "--derived")        { i <- i + 1; opts$derived <- args[[i]] }
    else if (a == "--out")       { i <- i + 1; opts$out <- args[[i]] }
    else if (a == "--min-hours") { i <- i + 1; opts$min_hours <- as.numeric(args[[i]]) }
    else stop("Unknown argument: ", a)
    i <- i + 1
  }
  opts
}

# ---- helpers ---------------------------------------------------------------

# write.csv drops the time from a midnight POSIXct, so an hour column reads
# "2026-01-01" on the hour and "2026-01-01 13:00:00" on every other. Bare
# as.POSIXct() takes its format from the first row and would collapse the whole
# column onto midnight. Parse explicitly, then fall back only where needed.
parse_hour <- function(x) {
  x <- trimws(as.character(x))
  ts <- suppressWarnings(as.POSIXct(x, format = "%Y-%m-%d %H:%M:%S", tz = "UTC"))
  gap <- is.na(ts) & nzchar(x) & !is.na(x)
  if (any(gap)) ts[gap] <- suppressWarnings(as.POSIXct(x[gap], format = "%Y-%m-%dT%H:%M:%S", tz = "UTC"))
  gap <- is.na(ts) & nzchar(x) & !is.na(x)
  if (any(gap)) ts[gap] <- suppressWarnings(as.POSIXct(x[gap], format = "%Y-%m-%d", tz = "UTC"))
  ts
}

local_hour <- function(x) as.integer(format(x, "%H", tz = TZ))
local_lab  <- function(x) format(x, "%d %b %H:%M", tz = TZ)

rule <- function(title) {
  cat("\n", strrep("=", 70), "\n", toupper(title), "\n", strrep("=", 70), "\n", sep = "")
}
sub_rule <- function(title) cat("\n--- ", title, " ---\n", sep = "")

need <- function(df, cols) all(cols %in% names(df))

# A bar chart with the y axis starting at zero and nothing decorative.
barchart <- function(x, y, xlab, ylab, main, col = "#2a78d6", labels = NULL) {
  op <- par(mar = c(4.4, 4.6, 3.2, 1.2), bg = "white", col.axis = "#54584a",
            col.lab = "#16180f", col.main = "#16180f", cex.axis = .85, las = 1)
  on.exit(par(op))
  bp <- barplot(y, names.arg = if (is.null(labels)) x else labels, col = col,
                border = NA, ylim = c(0, max(y, na.rm = TRUE) * 1.12),
                xlab = xlab, ylab = ylab, main = main)
  grid(nx = NA, ny = NULL, col = "#dcdcd2", lty = 1)
  barplot(y, col = col, border = NA, add = TRUE, axes = FALSE, names.arg = NA)
  invisible(bp)
}

open_png <- function(dir, name, w = 1100, h = 620) {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  p <- file.path(dir, name)
  png(p, width = w, height = h, res = 130)
  p
}

# ---- load ------------------------------------------------------------------

load_all <- function(d) {
  need_file <- function(f) {
    p <- file.path(d, f)
    if (!file.exists(p)) {
      stop("Missing ", p, ".\n",
           "  Run the pipeline first:\n",
           "    Rscript R/02_derive_flows.R --data data --out ", d, "\n",
           "    Rscript R/03_fetch_meteoswiss.R --stations ", d, "/stations.csv --out ", d, "\n",
           "    Rscript R/04_join_and_analyse.R --derived ", d)
    }
    p
  }
  net <- read.csv(need_file("network_hourly.csv"), stringsAsFactors = FALSE)
  flow <- read.csv(need_file("hourly_flow.csv"), stringsAsFactors = FALSE)
  net$hour  <- parse_hour(net$hour)
  flow$hour <- parse_hour(flow$hour)
  net  <- net[!is.na(net$hour), ]
  flow <- flow[!is.na(flow$hour), ]
  net  <- net[order(net$hour), ]

  net$local_hour <- local_hour(net$hour)
  net$is_weekend <- format(net$hour, "%u", tz = TZ) %in% c("6", "7")
  if ("precip_mm" %in% names(net)) {
    p <- net$precip_mm; p[is.na(p)] <- 0
    net$wet <- p > WET_MM
  }
  list(net = net, flow = flow)
}

# ---- A. what the window actually contains ---------------------------------

report_window <- function(net, flow) {
  rule("1. what this dataset is")
  cat(sprintf("Hours of bike data      : %d\n", nrow(net)))
  cat(sprintf("Window (local time)     : %s  to  %s\n",
              local_lab(min(net$hour)), local_lab(max(net$hour))))
  cat(sprintf("Stations                : %d\n", length(unique(flow$station_id))))
  cat(sprintf("Total movements         : %s\n",
              format(sum(net$total_turnover), big.mark = ",")))
  days <- as.numeric(difftime(max(net$hour), min(net$hour), units = "days"))
  cat(sprintf("Span                    : %.1f days\n", days))

  gaps <- as.numeric(diff(net$hour), units = "hours")
  missing <- sum(gaps > 1.5)
  cat(sprintf("Missing hours in span   : %d\n", round(sum(gaps[gaps > 1.5] - 1))))

  if ("mean_observations" %in% names(net)) {
    sub_rule("How much evidence per hour")
    cat(sprintf("Snapshots behind an hour: median %.1f, min %.1f, max %.1f\n",
                median(net$mean_observations), min(net$mean_observations),
                max(net$mean_observations)))
    thin <- sum(net$mean_observations < 2)
    cat(sprintf("Hours resting on <2 snapshots: %d of %d (%.0f%%)",
                thin, nrow(net), 100 * thin / nrow(net)))
    cat(if (thin > 0) "  <- these understate movement\n" else "\n")
  }
  if ("stations_moving" %in% names(net)) {
    cat(sprintf("Stations moving per hour: median %d of %d\n",
                round(median(net$stations_moving)), length(unique(flow$station_id))))
  }

  # Which network is this? Analysing the whole Swiss feed against a single
  # weather station is the failure mode the scoping exists to prevent, so it
  # gets said out loud rather than left for the reader to notice.
  if (need(flow, c("lat", "lon"))) {
    clat <- mean(flow$lat, na.rm = TRUE); clon <- mean(flow$lon, na.rm = TRUE)
    hav <- function(a1, o1, a2, o2) {
      p1 <- a1 * pi / 180; p2 <- a2 * pi / 180
      dp <- (a2 - a1) * pi / 180; dl <- (o2 - o1) * pi / 180
      2 * 6371 * asin(pmin(1, sqrt(sin(dp/2)^2 + cos(p1) * cos(p2) * sin(dl/2)^2)))
    }
    sp <- hav(clat, clon, flow$lat, flow$lon)
    sub_rule("Geographic scope")
    cat(sprintf("Centroid                : %.4f, %.4f\n", clat, clon))
    cat(sprintf("Spread from centroid    : median %.1f km, 90th pct %.1f km, max %.1f km\n",
                median(sp, na.rm = TRUE), quantile(sp, .9, na.rm = TRUE),
                max(sp, na.rm = TRUE)))
    if (quantile(sp, .9, na.rm = TRUE) > 15) {
      cat("\n  *** THIS IS NOT ONE CITY ***\n")
      cat("  These stations span tens of kilometres, so the single weather\n")
      cat("  station attached to them represents none of them well - least of\n")
      cat("  all for rain. Everything below mixes several cities together.\n")
      cat("  Collect with --city Bern, or filter before analysing.\n\n")
    }
  }

  wk <- table(format(net$hour, "%a", tz = TZ))
  sub_rule("Days of week covered")
  for (d in names(wk)) cat(sprintf("  %-4s %2d hours\n", d, wk[[d]]))
  if (!any(net$is_weekend)) {
    cat("  NOTE: no weekend hours yet - any weekday/weekend claim is impossible.\n")
  }
  invisible(NULL)
}

# ---- B. the daily cycle ----------------------------------------------------

report_daily <- function(net, outdir) {
  rule("2. the daily cycle")

  # THE TIMELINE IS ALWAYS HONEST. It is a description of what happened, one
  # bar per hour actually observed, asserting nothing about a typical day.
  p <- open_png(outdir, "01_demand_timeline.png", 1300, 620)
  op <- par(mar = c(4.6, 4.8, 3.4, 1.2), bg = "white", las = 1,
            col.axis = "#54584a", col.lab = "#16180f", cex.axis = .78)
  wet <- if ("wet" %in% names(net)) net$wet else rep(FALSE, nrow(net))
  bp <- barplot(net$total_turnover, col = ifelse(wet, "#0f6b5c", "#2a78d6"),
                border = NA, ylab = "movements per hour",
                names.arg = format(net$hour, "%H", tz = TZ),
                main = sprintf("Every hour collected, %s to %s (local)",
                               format(min(net$hour), "%d %b %H:%M", tz = TZ),
                               format(max(net$hour), "%d %b %H:%M", tz = TZ)))
  grid(nx = NA, ny = NULL, col = "#dcdcd2")
  barplot(net$total_turnover, col = ifelse(wet, "#0f6b5c", "#2a78d6"), border = NA,
          add = TRUE, axes = FALSE, names.arg = NA)
  # day boundaries, so the reader can see how many days this is
  dchg <- which(diff(as.integer(format(net$hour, "%d", tz = TZ))) != 0)
  if (length(dchg)) abline(v = (bp[dchg] + bp[dchg + 1]) / 2, col = "#8a8e7e", lty = 2)
  if (any(wet)) legend("topleft", c("dry hour", "wet hour"), fill = c("#2a78d6", "#0f6b5c"),
                       border = NA, bty = "n", cex = .8)
  par(op); dev.off()
  cat("  figure ->", p, "  (the timeline - always safe to show)\n")

  # THE HOUR-OF-DAY AVERAGE IS NOT, until there are enough days behind it.
  #
  # With two days collected, each bar of a "typical day" chart is the mean of
  # one or two numbers. Measured on the current window the two observations at
  # the same hour differ by a median factor of 2.7, and at 09:00 by 1710 vs 383.
  # A bar chart of those means looks like a finding and is an accident, so it is
  # only drawn once every hour has MIN_PER_HOUR observations - and even then it
  # is drawn with the full range, not the mean alone.
  MIN_PER_HOUR <- 3
  by_h <- aggregate(total_turnover ~ local_hour, data = net, FUN = mean)
  n_h  <- aggregate(total_turnover ~ local_hour, data = net, FUN = length); names(n_h)[2] <- "n"
  rg   <- aggregate(total_turnover ~ local_hour, data = net,
                    FUN = function(v) c(lo = min(v), hi = max(v)))
  by_h <- merge(by_h, n_h, by = "local_hour")
  by_h$lo <- rg$total_turnover[, "lo"]; by_h$hi <- rg$total_turnover[, "hi"]
  by_h <- by_h[order(by_h$local_hour), ]

  cat(sprintf("\nObservations per hour of day: min %d, median %d, max %d\n",
              min(by_h$n), median(by_h$n), max(by_h$n)))
  missing <- setdiff(0:23, by_h$local_hour)
  if (length(missing)) cat("Hours of day never observed: ", paste(missing, collapse = ", "), "\n", sep = "")

  if (min(by_h$n) < MIN_PER_HOUR) {
    cat(sprintf("\nNO 'typical day' CHART. Some hours rest on %d observation(s);\n", min(by_h$n)))
    cat(sprintf("  %d needed. At this sample the two readings for the same hour\n", MIN_PER_HOUR))
    sp <- by_h$hi / pmax(by_h$lo, 1)
    cat(sprintf("  differ by a median factor of %.1f (worst %.1f, at %02d:00) - a mean\n",
                median(sp), max(sp), by_h$local_hour[which.max(sp)]))
    cat("  of those would be an accident dressed as a pattern.\n")
    cat("  Use 01_demand_timeline.png instead. This unlocks with more days.\n")
  } else {
    p2 <- open_png(outdir, "01b_typical_day.png", 1100, 620)
    op <- par(mar = c(4.6, 4.8, 3.4, 1.2), bg = "white", las = 1,
              col.axis = "#54584a", cex.axis = .82)
    bp <- barplot(by_h$total_turnover, names.arg = sprintf("%02d", by_h$local_hour),
                  col = "#2a78d6", border = NA, ylim = c(0, max(by_h$hi) * 1.1),
                  xlab = "hour of day (local)", ylab = "movements per hour",
                  main = sprintf("Typical day (mean and range, n=%d-%d days)",
                                 min(by_h$n), max(by_h$n)))
    grid(nx = NA, ny = NULL, col = "#dcdcd2")
    barplot(by_h$total_turnover, col = "#2a78d6", border = NA, add = TRUE,
            axes = FALSE, names.arg = NA)
    arrows(bp, by_h$lo, bp, by_h$hi, angle = 90, code = 3, length = .03,
           col = "#16180f", lwd = 1)
    par(op); dev.off()
    cat("  figure ->", p2, "  (mean with observed range)\n")
  }
  invisible(by_h)
}

# Occupancy is the densest thing collected: the feed REPORTS it, at every
# snapshot, for every station - 1.5 million observations rather than 40 hourly
# aggregates. It also escapes the netting-out undercount that afflicts inferred
# flows. When the flow series is too thin to plot, this is not.
report_occupancy <- function(flow, outdir) {
  if (!("mean_bikes" %in% names(flow))) return(invisible(NULL))
  rule("2b. occupancy - the measured layer")
  cat(sprintf("Station-hours with an occupancy reading: %s\n",
              format(sum(!is.na(flow$mean_bikes)), big.mark = ",")))
  cat(sprintf("Bikes present per station: mean %.1f, median %.1f, max %.0f\n",
              mean(flow$mean_bikes, na.rm = TRUE), median(flow$mean_bikes, na.rm = TRUE),
              max(flow$mean_bikes, na.rm = TRUE)))
  empt <- mean(flow$mean_bikes < 0.5, na.rm = TRUE)
  cat(sprintf("Station-hours essentially empty (<0.5 bikes): %.0f%%\n", 100 * empt))
  cat("\nThis is measured, not inferred, and there are thousands of observations\n")
  cat("behind it. Anything about how full the network is - by station, by hour -\n")
  cat("is far better supported than anything about flows.\n")

  p <- open_png(outdir, "06_occupancy.png", 1100, 620)
  op <- par(mar = c(4.6, 4.8, 3.4, 1.2), bg = "white", las = 1,
            col.axis = "#54584a", cex.axis = .82)
  hist(flow$mean_bikes, breaks = 40, col = "#2a78d6", border = "white",
       xlab = "mean bikes present during the hour", ylab = "station-hours",
       main = sprintf("Occupancy across %s station-hours",
                      format(nrow(flow), big.mark = ",")))
  grid(nx = NA, ny = NULL, col = "#dcdcd2")
  par(op); dev.off(); cat("  figure ->", p, "\n")
  invisible(NULL)
}

# ---- C. Q3, vehicle types --------------------------------------------------

report_types <- function(net, outdir) {
  tc <- grep("^turnover_", names(net), value = TRUE)
  if (!length(tc)) {
    cat("\n(no per-type columns in network_hourly.csv - re-run 04 to add them)\n")
    return(invisible(NULL))
  }
  rule("3. vehicle types  (Q3)")
  tot <- sapply(tc, function(v) sum(net[[v]], na.rm = TRUE))
  tot <- tot[tot > 0]
  nm  <- sub("^turnover_", "", names(tot))
  for (i in seq_along(tot)) {
    cat(sprintf("  %-10s %8s movements  (%.1f%% of typed movement)\n",
                nm[i], format(tot[i], big.mark = ","), 100 * tot[i] / sum(tot)))
  }
  cat("\nNote: per-type movements do NOT sum to total_turnover. A swap - one\n")
  cat("e-bike out, one mechanical in - moves both type series while barely\n")
  cat("moving the total.\n")

  p <- open_png(outdir, "02_vehicle_types.png", 900, 560)
  barchart(nm, as.numeric(tot), "vehicle type", "movements",
           "Movements by vehicle type", col = "#2a78d6", labels = nm)
  dev.off(); cat("  figure ->", p, "\n")
  invisible(tot)
}

# ---- D. Q1/Q2, the weather relationship ------------------------------------

report_weather <- function(net, outdir, min_hours) {
  if (!("wet" %in% names(net))) {
    cat("\n(no precip_mm column - weather questions cannot be asked)\n")
    return(invisible(NULL))
  }
  rule("4. weather and demand  (Q1, Q2)")

  wet <- net$total_turnover[net$wet]
  dry <- net$total_turnover[!net$wet]
  cat(sprintf("Wet hours (>%.1f mm): %d      Dry hours: %d\n", WET_MM, length(wet), length(dry)))
  if (length(wet) == 0 || length(dry) == 0) {
    cat("Need both wet and dry hours before anything can be compared.\n")
    return(invisible(NULL))
  }

  sub_rule("Raw comparison - DESCRIPTIVE ONLY")
  cat(sprintf("  dry  mean %8.1f movements/hour\n", mean(dry)))
  cat(sprintf("  wet  mean %8.1f movements/hour\n", mean(wet)))
  cat(sprintf("  difference %+.1f%%\n", (mean(wet) / mean(dry) - 1) * 100))

  # The confounding check that decides whether the raw figure means anything.
  wh <- net$local_hour[net$wet]; dh <- net$local_hour[!net$wet]
  cat(sprintf("\n  BUT: wet hours fall at a median local hour of %.0f, dry at %.0f.\n",
              median(wh), median(dh)))
  if (abs(median(wh) - median(dh)) >= 3) {
    cat("  Rain and time-of-day are badly confounded in this window. The raw\n")
    cat("  figure above is mostly telling you WHEN it rained, not what rain does.\n")
  }

  sub_rule("Within commute hours only (07, 08, 17, 18 local)")
  pk <- net[net$local_hour %in% COMMUTE, ]
  pw <- pk$total_turnover[pk$wet]; pd <- pk$total_turnover[!pk$wet]
  if (length(pw) > 0 && length(pd) > 0) {
    cat(sprintf("  dry n=%2d mean %7.1f  |  wet n=%2d mean %7.1f   (%+.1f%%)\n",
                length(pd), mean(pd), length(pw), mean(pw),
                (mean(pw) / mean(pd) - 1) * 100))
    if (min(length(pw), length(pd)) < 5) {
      cat("  Sample far too small to mean anything yet.\n")
    }
  } else {
    cat("  Not enough commute hours in both conditions yet.\n")
  }

  sub_rule("Temperature bins  (Q2)")
  if ("temp_c" %in% names(net) && sum(!is.na(net$temp_c)) > 3) {
    br <- pretty(range(net$temp_c, na.rm = TRUE), n = 5)
    net$tb <- cut(net$temp_c, breaks = br, include.lowest = TRUE)
    tb <- aggregate(total_turnover ~ tb, data = net, FUN = mean)
    nb <- aggregate(total_turnover ~ tb, data = net, FUN = length); names(nb)[2] <- "n"
    tb <- merge(tb, nb, by = "tb")
    # merge() coerces the factor to character, which would print the bins in
    # alphabetical order - "[16,18]" after "(24,26]". Restore the numeric order.
    tb <- tb[order(match(as.character(tb$tb), levels(net$tb))), ]
    for (i in seq_len(nrow(tb))) {
      cat(sprintf("  %-14s mean %7.1f  (n=%d)\n", tb$tb[i], tb$total_turnover[i], tb$n[i]))
    }
    cat("  Temperature and hour of day both peak mid-afternoon; treat as descriptive.\n")
  }

  # The model, only when there is enough of a window to control for the cycle.
  sub_rule("Controlling for hour of day and weekend")
  if (nrow(net) < min_hours) {
    cat(sprintf("  SKIPPED. %d hours collected, %d required.\n", nrow(net), min_hours))
    cat("  A model with an hour-of-day factor needs several observations per\n")
    cat("  hour to separate weather from the daily cycle. Collect more first;\n")
    cat("  re-run with --min-hours to override.\n")
  } else {
    ok <- !is.na(net$temp_c) & !is.na(net$total_turnover)
    m <- lm(total_turnover ~ factor(local_hour) + is_weekend + wet + temp_c,
            data = net[ok, ])
    co <- summary(m)$coefficients
    for (term in c("wetTRUE", "temp_c", "is_weekendTRUE")) {
      if (term %in% rownames(co)) {
        cat(sprintf("  %-16s estimate %+9.2f   p = %.4f\n", term, co[term, 1], co[term, 4]))
      }
    }
    cat(sprintf("  adjusted R-squared: %.3f   (n = %d hours)\n",
                summary(m)$adj.r.squared, sum(ok)))
  }

  # Figure: demand and rain on a shared time axis, two panels, never two y-axes.
  p <- open_png(outdir, "03_demand_and_rain.png", 1200, 760)
  op <- par(mfrow = c(2, 1), mar = c(2.2, 4.6, 2.6, 1.2), oma = c(2.4, 0, 0, 0),
            bg = "white", las = 1, cex.axis = .82, col.axis = "#54584a")
  lab <- format(net$hour, "%H", tz = TZ)
  barplot(net$total_turnover, names.arg = lab, col = "#2a78d6", border = NA,
          ylab = "movements", main = "Bike movements per hour")
  grid(nx = NA, ny = NULL, col = "#dcdcd2")
  barplot(net$total_turnover, col = "#2a78d6", border = NA, add = TRUE, axes = FALSE, names.arg = NA)
  pr <- net$precip_mm; pr[is.na(pr)] <- 0
  barplot(pr, names.arg = lab, col = "#0f6b5c", border = NA,
          ylab = "rain (mm)", main = "Precipitation, same hours")
  grid(nx = NA, ny = NULL, col = "#dcdcd2")
  barplot(pr, col = "#0f6b5c", border = NA, add = TRUE, axes = FALSE, names.arg = NA)
  mtext("hour of day (local)", side = 1, outer = TRUE, line = 1, cex = .9, col = "#54584a")
  par(op); dev.off(); cat("\n  figure ->", p, "\n")
  invisible(NULL)
}

# ---- E. Q4, where people ride ----------------------------------------------

report_spatial <- function(flow, net, outdir) {
  rule("5. where the demand is  (Q4)")
  if (!need(flow, c("lat", "lon", "turnover"))) {
    cat("(hourly_flow.csv has no coordinates - re-run 02)\n"); return(invisible(NULL))
  }
  st <- aggregate(turnover ~ station_id, data = flow, FUN = sum)
  meta <- flow[!duplicated(flow$station_id), c("station_id", "name", "lat", "lon")]
  st <- merge(st, meta, by = "station_id")
  st <- st[order(-st$turnover), ]

  cat(sprintf("Stations with any movement: %d of %d\n",
              sum(st$turnover > 0), nrow(st)))
  tot <- sum(st$turnover)
  for (k in c(5, 10, 20, 50)) {
    if (k <= nrow(st)) {
      cat(sprintf("  top %3d stations = %4.1f%% of all movements\n",
                  k, 100 * sum(head(st$turnover, k)) / tot))
    }
  }
  sub_rule("Busiest 10")
  for (i in seq_len(min(10, nrow(st)))) {
    cat(sprintf("  %-42s %5d\n", substr(st$name[i], 1, 40), st$turnover[i]))
  }

  # Wet vs dry share per station: the actual Q4 test, once there is enough rain.
  if ("wet" %in% names(net)) {
    wh <- net$hour[net$wet]; dh <- net$hour[!net$wet]
    if (length(wh) >= 3 && length(dh) >= 3) {
      sw <- aggregate(turnover ~ station_id, data = flow[flow$hour %in% wh, ], FUN = sum)
      sd <- aggregate(turnover ~ station_id, data = flow[flow$hour %in% dh, ], FUN = sum)
      names(sw)[2] <- "wet"; names(sd)[2] <- "dry"
      sh <- merge(merge(sw, sd, by = "station_id"), meta, by = "station_id")
      sh$wet_share <- sh$wet / sum(sh$wet)
      sh$dry_share <- sh$dry / sum(sh$dry)
      sh$shift <- sh$wet_share - sh$dry_share
      sh <- sh[order(-abs(sh$shift)), ]
      sub_rule("Stations whose share of the network shifts most in rain")
      cat("  (positive = busier than usual when wet)\n")
      for (i in seq_len(min(8, nrow(sh)))) {
        cat(sprintf("  %-38s %+6.2f pp   (wet %d / dry %d)\n",
                    substr(sh$name[i], 1, 36), 100 * sh$shift[i], sh$wet[i], sh$dry[i]))
      }
      cat("  With few wet hours these are noise. Revisit once rain is spread\n")
      cat("  across several days and times of day.\n")
    }
  }

  p <- open_png(outdir, "04_station_map.png", 1000, 900)
  op <- par(mar = c(4.2, 4.4, 3.2, 1.2), bg = "white", las = 1,
            col.axis = "#54584a", cex.axis = .8)
  r <- st$turnover
  cexs <- 0.5 + 2.6 * sqrt(r / max(r, 1))
  plot(st$lon, st$lat, cex = cexs, pch = 21, bg = "#2a78d644", col = "#2a78d6",
       xlab = "longitude", ylab = "latitude",
       main = sprintf("%d stations, sized by movements", nrow(st)),
       asp = 1 / cos(mean(st$lat, na.rm = TRUE) * pi / 180))
  grid(col = "#dcdcd2", lty = 1)
  top <- head(st, 3)
  text(top$lon, top$lat, substr(top$name, 1, 18), pos = 3, cex = .62, col = "#16180f")
  par(op); dev.off(); cat("\n  figure ->", p, "\n")

  p2 <- open_png(outdir, "05_top_stations.png", 1000, 620)
  op <- par(mar = c(4.4, 13, 3.2, 1.2), bg = "white", las = 1,
            col.axis = "#54584a", cex.axis = .78)
  tp <- head(st, 12)
  barplot(rev(tp$turnover), names.arg = rev(substr(tp$name, 1, 30)), horiz = TRUE,
          col = "#2a78d6", border = NA, xlab = "movements",
          main = "Busiest stations")
  par(op); dev.off(); cat("  figure ->", p2, "\n")
  invisible(st)
}

# ---- F. the numbers to paste into the methods section ----------------------

report_methods <- function(net, flow) {
  rule("6. numbers for your methods section")
  cat(sprintf("Collection window (local): %s to %s\n",
              local_lab(min(net$hour)), local_lab(max(net$hour))))
  cat(sprintf("Hours analysed           : %d\n", nrow(net)))
  cat(sprintf("Stations                 : %d\n", length(unique(flow$station_id))))
  cat(sprintf("Station-hours            : %s\n", format(nrow(flow), big.mark = ",")))
  cat(sprintf("Total movements          : %s\n", format(sum(net$total_turnover), big.mark = ",")))
  if ("mean_observations" %in% names(net)) {
    cat(sprintf("Snapshots per hour       : median %.1f (min %.1f, max %.1f)\n",
                median(net$mean_observations), min(net$mean_observations),
                max(net$mean_observations)))
  }
  if ("wet" %in% names(net)) {
    cat(sprintf("Wet hours / dry hours    : %d / %d\n", sum(net$wet), sum(!net$wet)))
    cat(sprintf("Total precipitation      : %.1f mm\n", sum(net$precip_mm, na.rm = TRUE)))
  }
  if ("temp_c" %in% names(net)) {
    cat(sprintf("Temperature range        : %.1f to %.1f C\n",
                min(net$temp_c, na.rm = TRUE), max(net$temp_c, na.rm = TRUE)))
  }
  cat(sprintf("Weekend hours            : %d\n", sum(net$is_weekend)))
  cat("\nLimitations to state explicitly:\n")
  cat("  - Occupancy is sampled roughly every 15 minutes, so a bike leaving and\n")
  cat("    another arriving in the same window nets to zero. All movement counts\n")
  cat("    are a floor, and the undercount is worst at the busiest stations.\n")
  cat("  - One weather station represents the whole network. Temperature travels\n")
  cat("    well over this distance; precipitation does not (docs/DATA_QUALITY.md).\n")
  cat("  - Station capacity is nominal, not physical docks, so fill rate and\n")
  cat("    'full' are not measurable from this feed.\n")
}

# ---- main ------------------------------------------------------------------

main <- function() {
  opts <- parse_args(commandArgs(trailingOnly = TRUE))
  d <- load_all(opts$derived)
  net <- d$net; flow <- d$flow

  if (nrow(net) == 0) stop("network_hourly.csv has no usable rows.")

  report_window(net, flow)
  report_daily(net, opts$out)
  report_occupancy(flow, opts$out)
  report_types(net, opts$out)
  report_weather(net, opts$out, opts$min_hours)
  report_spatial(flow, net, opts$out)
  report_methods(net, flow)

  cat("\n", strrep("=", 70), "\n", sep = "")
  cat("Figures written to ", normalizePath(opts$out, mustWork = FALSE), "\n", sep = "")
  cat(strrep("=", 70), "\n", sep = "")
}

main()
