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
`07:45:05` — so something upstream does run every 15 minutes. But what actually
*reaches* the API is sparse and irregular. Polling 110 times over 38 minutes
returned only **three distinct snapshots**, and there was a **75-minute stretch
in which no new snapshot appeared at all**.

> A caution about measuring this. A first probe lasting a few minutes saw
> `06:15:05` and `06:30:05` and suggested a tidy 15-minute cadence. Running for
> 38 minutes showed that conclusion was wrong. Probe for an hour or more before
> you trust a number, and re-probe rather than assuming today matches.

**Consequence.** Fifteen minutes is a best case, not a guarantee. Some hours
will carry four observations and some only one; `02_derive_flows.R` writes an
`observations` column per station-hour so you can tell them apart, and reports
the median and maximum interval between snapshots. Quote both in the methods
section rather than a single nominal interval.

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

*If you have data collected before this guard existed, treat short-gap events
with suspicion — a change and its exact reversal a minute apart is the tell.*

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
