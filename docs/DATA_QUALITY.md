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

## 1. It publishes every ~15 minutes, not every minute

The feed sets `ttl: 60`, which reads as "refreshes every 60 seconds". It does
not. Observed `last_updated` values land on the quarter hour:

```
06:15:05   06:30:05   07:45:05   08:00:05 ...
```

Fifteen polls a minute apart return byte-identical bodies. A 22-minute test run
at 20-second polling made 22 requests and wrote 2 snapshots — the other 20 were
the same data.

**Consequence.** The effective time resolution of this dataset is 15 minutes.
The original plan's 60-second interval, and the proposal's 5-minute interval,
were both describing a precision the source does not offer. Polling faster is
still worth doing — it catches each publication within ~30 s of it appearing,
rather than up to 15 minutes late — but it does not produce finer data.

**Consequence for the flow inference.** Differencing recovers only the *net*
change over each 15-minute window. A bike leaving and another arriving in the
same window nets to zero and is invisible. This undercount is worse than a
5-minute interval would have given, and worst at the busiest stations — a
systematic bias, not noise. Say so in the limitations, and if you want to
quantify it, note that this is now unfixable from the source side: no amount of
polling recovers what the publisher never published.

## 2. Replicas serve snapshots out of order

Consecutive requests, seconds apart, returned:

```
07:34:20   last_updated = 06:30:05
07:35:01   last_updated = 06:15:05      <- fifteen minutes older
```

The endpoint sits behind several caches that are not in step. This is not
occasional: `If-None-Match` with a single ETag returned `200` where the same
request carrying *both* recently-seen ETags returned `304`, which is the
signature of two replicas alternating.

**Consequence.** Naive differencing turns this into fabricated activity. Going
06:30 → 06:15 → 06:30 reads as a departure followed by a matching arrival at
every station that moved in between, all timestamped wrongly. It inflates
turnover and adds it disproportionately to busy stations, which is exactly
where the analysis looks.

**Handled.** `01_collect_publibike.R` drops any snapshot whose `last_updated` is
not strictly newer than the newest already accepted (`MONOTONIC_GATE`), and logs
it as `stale_replica` in the poll log so the rate is visible rather than hidden.

*If you have data collected before this guard existed, treat short-gap events
with suspicion — a change and its exact reversal a minute apart is the tell.*

## 3. Conditional GET works, so frequent polling is nearly free

The endpoint honours `If-None-Match` and returns `304` with an empty body, and
it accepts several ETags in one header — necessary given (2), since one ETag
only silences one replica. It also serves gzip: 27 KB on the wire instead of
634 KB.

**Consequence.** Polling every 30 seconds costs almost nothing, so there is no
reason to poll slowly to be polite. The collector writes a row only when the
feed advances, so the file contains one record per publication instead of one
per poll — about **96 snapshots a day, ~320 KB gzipped** for the Bern network,
against the ~28 MB a day that writing every poll of the whole network would
have produced.

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
- **Anything at finer than 15-minute resolution.**
- **Anything about Basel, Lugano or Sion** from this feed, without first
  establishing that their stations report at all.
