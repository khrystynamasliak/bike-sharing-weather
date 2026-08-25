# What the feed actually does

Everything here was measured against
`https://api.mobidata-bw.de/sharing/gbfs/v3/velospot_ch` on **25 August 2026**.
None of it is documented by the publisher. Re-measure before relying on it:

```bash
Rscript R/01_collect_publibike.R --probe --probe-minutes 45
```

The point of this document is that each finding below changes what the data can
support. A methods section that quotes the feed's advertised behaviour rather
than its observed behaviour will overstate what the dataset measures.

---

## 1. It publishes far less often than `ttl: 60` claims — and irregularly

The feed sets `ttl: 60`, which reads as "refreshes every 60 seconds". It does
not, and the truth is worse than a simple longer interval.

Snapshot timestamps land on the quarter hour — `06:15:05`, `06:30:05`,
`07:45:05` — and the best measurement available confirms roughly that cadence,
with stalls.

**13.5 hours of continuous collection** (24–25 Aug, polled every 60 s) produced
**619 polls but only 39 distinct network states**:

| | |
|---|---|
| median interval between snapshots | 15.1 min |
| shortest | 12.2 min |
| longest | 75.4 min |
| gaps of 16 min or less | 68% |
| polls that returned identical data | 93.5% |

> A caution about measuring this. A first probe of a few minutes saw two
> snapshots 15 minutes apart and suggested a tidy cadence. A 38-minute probe
> then landed inside a stall and suggested something far worse. Neither was
> representative. Trust a long collection run over a short probe, and quote the
> realised distribution rather than a nominal figure.

**Consequence.** Fifteen minutes is the typical case, not a guarantee: about a
third of intervals are longer, and stalls past an hour happen. Some hours carry
four observations and some one; `02_derive_flows.R` writes an `observations`
column per station-hour so you can tell them apart, and reports the median and
maximum interval. Quote both in the methods section.

The original plan's 60-second interval and the proposal's 5-minute interval
were both describing a precision the source does not offer. Polling fast is
still worth doing — it catches each snapshot shortly after it appears, and each
poll is free — but it does not produce finer data.

**Consequence for the flow inference.** Differencing recovers only the *net*
change over each 15-minute window. A bike leaving and another arriving in the
same window nets to zero and is invisible. This undercount is worse than a
5-minute interval would have given, and worst at the busiest stations — a
systematic bias, not noise. Say so in the limitations, and if you want to
quantify it, note that this is now unfixable from the source side: no amount of
polling recovers what the publisher never published.

### The 93.5% figure is the whole argument for the collector's design

Polling every 60 seconds and storing every response wrote the same snapshot
about fifteen times over. That is what the first version of the collector did,
and it is why `data/` holds 13 MB for half a day of a feed that only produced
39 genuinely distinct observations.

## 2. Replicas serve snapshots out of order, and the spread is wide

The endpoint sits behind several caches that are not in step. What each returns
depends on which replica the load balancer picks, and they can be far apart:

```
served 07:34:20  ->  snapshot 06:30:05    64 min old
served 07:35:01  ->  snapshot 06:15:05    80 min old
served 07:46:56  ->  snapshot 07:45:05     2 min old
served 07:52:59  ->  snapshot 06:30:05    83 min old
served 07:59:00  ->  snapshot 07:45:05    14 min old
served 08:06:03  ->  snapshot 06:30:05    96 min old
```

Snapshots **90 minutes apart** were served interchangeably inside one window.
This is not occasional: `If-None-Match` with a single ETag returned `200` where
the same request carrying *both* recently-seen ETags returned `304` — the
signature of replicas alternating.

**Consequence.** Recording that stream in arrival order fabricates activity.
06:30 → 06:15 → 06:30 reads as a departure and then a matching arrival at every
station that moved in between, all timestamped wrongly. It inflates turnover and
does so most at busy stations, which is exactly where the analysis looks.

**Handled — but not the obvious way.** The intuitive fix is "accept only
snapshots newer than the newest so far". That is wrong here, and measurably so:
because the replicas hold *different* snapshots, an older-looking response is
often one this run has never recorded. In a 22-minute test the collector
rejected `06:30:05` as stale while holding `06:15:05` and `07:45:05` — throwing
away a real, useful, intermediate observation.

The collector therefore keys on snapshot **identity**: each distinct
`last_updated` is stored exactly once, whenever it turns up, and repeats are
logged as `already_recorded`. Arrival order does not matter, because
`02_derive_flows.R` sorts by `feed_last_updated` before differencing and
de-duplicates on `(station_id, observed_at)`. The series it works from is
chronological however the parts arrived.

A side effect worth noting: because out-of-step replicas are a *source* of
snapshots rather than only a nuisance, this collects more history than a
strictly-newer rule would.

**Data collected before this guard existed is recoverable, and is recovered
automatically.** In the 24–25 Aug files, 3.9% of polls returned to a network
state already seen, and the feed's own clock — the newest `last_reported` across
all stations — ran backwards on 4.4% of transitions, by up to 105 minutes.
Differencing that in poll order would have fabricated flows.

The fix needs no new fields. The newest `last_reported` in a poll identifies the
snapshot it came from, and on that data the mapping is exactly one-to-one: 619
polls, 39 distinct network states, 39 distinct values of `max(last_reported)`.
`02_derive_flows.R` detects files with no `feed_last_updated`, keys on that
instead, and collapses the repeats — recovering the true 39-snapshot series from
1.03 million rows.

## 3. Conditional GET works, so frequent polling is nearly free

The endpoint honours `If-None-Match` and returns `304` with an empty body, and
it accepts several ETags in one header — necessary given (2), since one ETag
only silences one replica. It also serves gzip: 27 KB on the wire instead of
634 KB.

**Consequence.** Polling every 30 seconds costs almost nothing, so there is no
reason to poll slowly to be polite. The collector stores each distinct snapshot
once rather than one row per poll, so volume is set by the feed, not the
interval: at best (a true 15-minute cadence) about **96 snapshots and ~320 KB
gzipped a day** for the Bern network, and less when the feed stalls. Writing
every poll of the whole network instead would have been ~28 MB a day of
near-duplicates.

## 4. `last_reported` is the real event clock

Publication is coarse, but each station reports when *it* last changed, to the
second:

```json
{"station_id": "PIB:Station:168", "num_vehicles_available": 5,
 "last_reported": "2026-08-25T04:03:39.000+00:00"}
```

**Consequence.** A change detected between two snapshots can usually be
timestamped to the second rather than to the 15-minute window. `02_derive_flows.R`
uses `last_reported` when it falls inside the interval between the two
observations, and falls back to the snapshot time otherwise; `event_time_source`
records which was used for every event. This matters most at hour boundaries,
which is precisely where the weather join happens.

## 5. Most of the network is not reporting

Age of `last_reported`, network-wide, at 06:30 UTC:

| | |
|---|---|
| within 1 hour | 31% |
| within 24 hours | 83% |
| silent over 24 hours | 17% |
| median age | 10.7 hours |

It varies enormously by city:

| City (5 km radius) | Stations | Reported within 1 h | Median age |
|---|---|---|---|
| Fribourg | 62 | 73% | 0.5 h |
| **Bern** | **272** | **68%** | **0.4 h** |
| Zürich | 232 | 56% | 0.7 h |
| Biel/Bienne | 59 | 32% | 9.6 h |
| Aarau | 25 | 20% | 9.6 h |
| Basel | 299 | 15% | 15.5 h |
| Lugano | 60 | 10% | 11.3 h |
| Sion | 59 | 10% | 16.1 h |

**Consequence.** A silent station produces a flat series, which differencing
correctly reads as zero flow — but "zero because nobody rode" and "zero because
the station is offline" are different things, and averaging them together
deflates every network-level demand figure. `02_derive_flows.R` prints the
liveness breakdown; consider excluding stations silent for the whole window
from network turnover, and report how many you excluded.

**Consequence for city choice.** Bern is the right network to study, and not
only because the proposal said so: it is among the two healthiest in the feed
and the largest of those. Basel looks attractive on station count and is
essentially dead in this feed.

## 5b. How far does one weather station's reading travel?

The single-station join is the project's biggest methodological bet, so it was
measured rather than assumed. Four MeteoSwiss stations, same 19 hours as the
first collection window, all compared against **BER** (Zollikofen, 4.9 km from
the centre of Bern):

| Station | Distance | Elevation | Mean abs. temp difference | Total rain | Wet/dry hours agreeing |
|---|---|---|---|---|---|
| **BER** | 4.9 km | 553 m | — | 23.2 mm | — |
| MUB (Mühleberg) | 13.1 km | 480 m | 0.60 °C (r = 0.985) | 18.6 mm | 89% |
| SPF (Schüpfheim) | 42.9 km | 744 m | 1.14 °C (r = 0.958) | **7.4 mm** | **74%** |
| BAN (Bantiger) | 7.0 km | 942 m | *publishes neither* | — | — |

**Temperature travels; rain does not.** At 13 km the temperature series is
effectively interchangeable — 0.6 °C apart, correlated at 0.985. Rainfall over
the same hours is already 20% lower. At 43 km the station reports **less than a
third of the rain** and disagrees about whether it was raining at all in a
quarter of the hours.

The wettest hour makes it concrete: BER recorded 10.2 mm, Mühleberg 8.2 mm,
Schüpfheim 2.8 mm — one weather event, three quite different stories.

**Consequence.** A compact city network against a weather station a few
kilometres away is defensible, and is what the pipeline now does. The same
method applied to the full Swiss feed — whose centroid falls 43 km from Bern,
next to Schüpfheim — would have attached roughly a third of the true rainfall to
Bern's traffic. The scoping decision is not tidiness; it is the difference
between measuring the weather and measuring a different valley.

Residual error to report in the limitations: even at 5 km, precipitation is
point-measured and the network spans 5 km in every direction, so hourly rain is
an approximation for most stations in the network.

### Nearest is not the same as usable

Bantiger is 7 km from the centre and listed as an automatic weather station, but
it publishes **only radiation and sunshine** — no temperature, no precipitation.
Chosen blindly it produces a weather table whose analysis columns are entirely
empty, and `04_join_and_analyse.R` then joins successfully against nothing.

`03_fetch_meteoswiss.R` now checks that `temp_c` and `precip_mm` are actually
populated. If the station was auto-selected it walks down the list of nearest
stations until one qualifies; if it was named explicitly with `--station-abbr`
it stops with an error rather than silently returning empty columns.

## 6. Fields the spec promises and this feed does not deliver

`num_docks_available` and `num_bikes_disabled` are absent from every record.
Every station is `is_virtual_station: true`, so `capacity` is a nominal
allowance for a geofenced area, not a count of physical docks.

**Consequence.** Occupancy, fill rate and "empty" are measurable. **Dock
saturation is not.** The derived column is named `at_nominal_capacity` rather
than `is_full` to stop that distinction being lost. The proposal's fallback
question — is dock capacity allocated where demand is? — still works, since it
needs `capacity` rather than live dock counts, but it is a question about
nominal allowances and should be phrased that way.

## 7. Vehicle types

Four types are published: `ebike`, `mbike` (mechanical), `hbike` (mechanical,
private battery), `escooter`. Network-wide at one snapshot: 13,052 e-bikes,
5,700 mechanical, 298 e-scooters, 108 hbike.

`02_derive_flows.R` differences each type separately, so `departures_ebike`,
`arrivals_mbike` and so on are available per station-hour. Note that a swap —
an e-bike out, a classic in — leaves the total unchanged while both type series
move; those rows are counted as events, which is why per-type turnover can
exceed total turnover.

---

## Things this project cannot claim

- **Individual trips.** Only net change per station per 15 minutes.
- **Real turnover at busy stations.** Systematically undercounted, worst where
  demand is highest.
- **Dock saturation.** Not published.
- **Anything at finer than 15-minute resolution** — and not reliably that:
  some hours carry a single observation. Check the `observations` column.
- **Anything about Basel, Lugano or Sion** from this feed, without first
  establishing that their stations report at all.
