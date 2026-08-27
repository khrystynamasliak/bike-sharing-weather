#!/usr/bin/env Rscript
# ============================================================================
# 06_first_plots.R
#
# Six starter plots, one self-contained block each.
#
# This is NOT the report generator - that is 05_explore.R, which prints the
# numbers for a methods section and gates the charts that the sample cannot yet
# support. This file is here to be READ, COPIED AND CHANGED: each block is
# about fifteen lines, names the file it reads and the grain it works at, and
# does one thing. Actual row counts are printed when it runs - never frozen in
# a comment, where they go stale within a day.
#
# Every plot here is one the current data actually supports. The obvious
# missing one - mean demand by hour of day - is deliberately absent: with two
# days collected each bar would average one or two numbers. See 05_explore.R,
# which explains what would unlock it.
#
# Usage:
#   Rscript 06_first_plots.R
#   Rscript 06_first_plots.R --derived derived --out figures
#
# Dependencies: base R only.
# ============================================================================

local({
  if (isTRUE(l10n_info()[["UTF-8"]])) return(invisible(NULL))
  for (loc in c("C.UTF-8", "en_US.UTF-8", "de_CH.UTF-8", "UTF-8"))
    if (nzchar(suppressWarnings(Sys.setlocale("LC_CTYPE", loc)))) break
})

TZ  <- "Europe/Zurich"        # never hard-code +2; DST changes in October
BLUE <- "#2a78d6"; GREEN <- "#0f6b5c"; ORANGE <- "#eb6834"; GREY <- "#dcdcd2"

opts <- list(derived = "derived", out = "figures")
a <- commandArgs(trailingOnly = TRUE); i <- 1
while (i <= length(a)) {
  if (a[[i]] == "--derived") { i <- i + 1; opts$derived <- a[[i]] }
  else if (a[[i]] == "--out") { i <- i + 1; opts$out <- a[[i]] }
  i <- i + 1
}
dir.create(opts$out, recursive = TRUE, showWarnings = FALSE)

# ---- the two lines that bite everyone ---------------------------------------
# write.csv drops the time from a midnight POSIXct, so the hour column is
# "2026-08-25" on the hour and "2026-08-25 13:00:00" otherwise. Bare
# as.POSIXct() picks ONE format from the first row - and if that row is a
# midnight, every reading in the file collapses onto midnight.
parse_hour <- function(x) {
  x  <- trimws(as.character(x))
  ts <- suppressWarnings(as.POSIXct(x, format = "%Y-%m-%d %H:%M:%S", tz = "UTC"))
  g  <- is.na(ts) & nzchar(x)
  if (any(g)) ts[g] <- suppressWarnings(as.POSIXct(x[g], format = "%Y-%m-%d", tz = "UTC"))
  ts
}

fig <- function(name, w = 1200, h = 640) {
  p <- file.path(opts$out, name); png(p, width = w, height = h, res = 130)
  par(mar = c(4.6, 4.8, 3.4, 1.4), bg = "white", las = 1,
      col.axis = "#54584a", col.lab = "#16180f", col.main = "#16180f", cex.axis = .82)
  p
}
done <- function(p) { dev.off(); cat("  ->", p, "\n") }

net  <- read.csv(file.path(opts$derived, "network_hourly.csv"), stringsAsFactors = FALSE)
flow <- read.csv(file.path(opts$derived, "hourly_flow.csv"),    stringsAsFactors = FALSE)
net$hour  <- parse_hour(net$hour)
flow$hour <- parse_hour(flow$hour)
net <- net[order(net$hour), ]

cat("network_hourly.csv :", nrow(net),  "hours\n")
cat("hourly_flow.csv    :", nrow(flow), "station-hours,",
    length(unique(flow$station_id)), "stations\n\n")


# ============================================================================
# PLOT 1 — the timeline            reads: network_hourly.csv   grain: one hour
#
# One bar per hour actually observed. This is a description of what happened,
# so it is honest at any sample size - unlike an average over hour-of-day,
# which needs many days before it means anything.
# ============================================================================
p <- fig("p1_timeline.png", 1400)
wet <- net$precip_mm > 0.1 & !is.na(net$precip_mm)
bp  <- barplot(net$total_turnover, col = ifelse(wet, GREEN, BLUE), border = NA,
               names.arg = format(net$hour, "%H", tz = TZ),
               ylab = "movements per hour",
               main = sprintf("Every hour collected  (%s to %s, local)",
                              format(min(net$hour), "%d %b %H:%M", tz = TZ),
                              format(max(net$hour), "%d %b %H:%M", tz = TZ)))
grid(nx = NA, ny = NULL, col = GREY)
barplot(net$total_turnover, col = ifelse(wet, GREEN, BLUE), border = NA,
        add = TRUE, axes = FALSE, names.arg = NA)
# dashed line wherever the calendar day changes, so the reader sees 2 days
dchg <- which(diff(as.integer(format(net$hour, "%d", tz = TZ))) != 0)
if (length(dchg)) abline(v = (bp[dchg] + bp[dchg + 1]) / 2, col = "#8a8e7e", lty = 2)
legend("topleft", c("dry hour", "wet hour"), fill = c(BLUE, GREEN), border = NA, bty = "n")
done(p)


# ============================================================================
# PLOT 2 — occupancy               reads: hourly_flow.csv    grain: station-hour
#
# The best-supported thing in the dataset. Occupancy is REPORTED by the feed,
# not inferred by subtraction, so it escapes the netting-out undercount that
# makes every flow count a floor.
# ============================================================================
p <- fig("p2_occupancy.png")
hist(flow$mean_bikes, breaks = 40, col = BLUE, border = "white",
     xlab = "mean bikes present during the hour", ylab = "station-hours",
     main = sprintf("Occupancy across %s station-hours",
                    format(nrow(flow), big.mark = ",")))
grid(nx = NA, ny = NULL, col = GREY)
abline(v = median(flow$mean_bikes, na.rm = TRUE), col = ORANGE, lwd = 2, lty = 2)
text(median(flow$mean_bikes, na.rm = TRUE), par("usr")[4] * .9,
     sprintf(" median %.1f", median(flow$mean_bikes, na.rm = TRUE)), col = ORANGE, pos = 4)
done(p)


# ============================================================================
# PLOT 3 — the network on a map    reads: hourly_flow.csv    grain: station
#
# asp corrects for longitude compression at this latitude, so the shape is not
# stretched. Circle AREA is proportional to movements - hence sqrt on the radius.
# ============================================================================
st <- aggregate(turnover ~ station_id, data = flow, FUN = sum)
st <- merge(st, flow[!duplicated(flow$station_id), c("station_id", "name", "lat", "lon")],
            by = "station_id")
st <- st[order(-st$turnover), ]

p <- fig("p3_map.png", 1100, 950)
plot(st$lon, st$lat, cex = 0.5 + 2.6 * sqrt(st$turnover / max(st$turnover)),
     pch = 21, bg = paste0(BLUE, "44"), col = BLUE,
     xlab = "longitude", ylab = "latitude",
     asp = 1 / cos(mean(st$lat) * pi / 180),
     main = sprintf("%d stations, circle area = movements", nrow(st)))
grid(col = GREY)
text(head(st$lon, 3), head(st$lat, 3), substr(head(st$name, 3), 1, 18),
     pos = 3, cex = .65)
done(p)


# ============================================================================
# PLOT 4 — busiest stations        reads: hourly_flow.csv    grain: station
#
# rev() because barplot(horiz = TRUE) draws bottom-up and the rank should read
# top-down.
# ============================================================================
top <- head(st, 12)
p <- fig("p4_top_stations.png", 1100, 680)
par(mar = c(4.6, 14, 3.4, 1.4))
barplot(rev(top$turnover), names.arg = rev(substr(top$name, 1, 30)), horiz = TRUE,
        col = BLUE, border = NA, xlab = "movements",
        main = "Busiest stations over the window")
grid(nx = NULL, ny = NA, col = GREY)
barplot(rev(top$turnover), horiz = TRUE, col = BLUE, border = NA,
        add = TRUE, axes = FALSE, names.arg = NA)
done(p)


# ============================================================================
# PLOT 5 — e-bike vs mechanical    reads: network_hourly.csv  grain: one hour
#
# GROUPED, not stacked. A swap - one e-bike out, one mechanical in - moves both
# series while barely moving the total, so the two do NOT sum to total_turnover
# and a stack would assert a partition that does not exist.
# ============================================================================
p <- fig("p5_types.png", 1400)
m <- rbind(net$turnover_ebike, net$turnover_mbike)
barplot(m, beside = TRUE, col = c(BLUE, ORANGE), border = NA,
        names.arg = format(net$hour, "%H", tz = TZ),
        ylab = "movements per hour", main = "E-bike against mechanical, per hour")
grid(nx = NA, ny = NULL, col = GREY)
# axisnames = FALSE, not names.arg = NA: for a grouped matrix R wants one
# name per group, and a length-1 NA is rejected as "incorrect number of names".
barplot(m, beside = TRUE, col = c(BLUE, ORANGE), border = NA,
        add = TRUE, axes = FALSE, axisnames = FALSE)
legend("topleft", c(sprintf("e-bike (%s)", format(sum(net$turnover_ebike), big.mark = ",")),
                    sprintf("mechanical (%s)", format(sum(net$turnover_mbike), big.mark = ","))),
       fill = c(BLUE, ORANGE), border = NA, bty = "n")
done(p)


# ============================================================================
# PLOT 6 — which stations drain     reads: hourly_flow.csv    grain: station
# net_flow = arrivals - departures. Summed over the window it shows stations
# that structurally lose bikes (commuters ride away) against those that gain.
# This is the rebalancing question, and it needs no weather at all.
# ============================================================================
nf <- aggregate(net_flow ~ station_id, data = flow, FUN = sum)
nf <- merge(nf, flow[!duplicated(flow$station_id), c("station_id", "name")], by = "station_id")
nf <- nf[order(nf$net_flow), ]
ext <- rbind(head(nf, 8), tail(nf, 8))          # 8 biggest drainers and fillers

p <- fig("p6_net_flow.png", 1100, 760)
par(mar = c(4.6, 14, 3.4, 1.4))
barplot(ext$net_flow, names.arg = substr(ext$name, 1, 30), horiz = TRUE,
        col = ifelse(ext$net_flow < 0, ORANGE, BLUE), border = NA,
        xlab = "net change in bikes over the window  (arrivals − departures)",
        main = "Stations that drain (orange) and fill (blue)")
grid(nx = NULL, ny = NA, col = GREY)
barplot(ext$net_flow, horiz = TRUE, col = ifelse(ext$net_flow < 0, ORANGE, BLUE),
        border = NA, add = TRUE, axes = FALSE, names.arg = NA)
abline(v = 0, col = "#16180f")
done(p)

cat("\nSix figures written to ", normalizePath(opts$out, mustWork = FALSE), "\n", sep = "")
cat("Files read: ", opts$derived, "/network_hourly.csv and ", opts$derived,
    "/hourly_flow.csv\n", sep = "")
