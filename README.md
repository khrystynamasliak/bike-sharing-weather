# Weather sensitivity of bike-share demand in Switzerland

Measuring how weather affects PubliBike demand, using two independently
published data sources joined on time.

**Status:** collecting from 25 August 2026 · Bern network (272 stations within
5 km of the centre) · polled every 30 s; the feed publishes irregularly, at
best every ~15 min

---

## The two data sources

| | Source 1 | Source 2 |
|---|---|---|
| Publisher | PubliBike / Velospot (private operator) | MeteoSwiss (federal agency) |
| Data | Station occupancy | Weather, per hour |
| Access | GBFS 3.0 feed, `api.mobidata-bw.de` | STAC API, `data.geo.admin.ch` |
| Collection | Self-collected — no history is published | Downloaded |

PubliBike publishes **no historical trip data** — GBFS reports current system
state and retains nothing. This project therefore builds its own history by
polling the live feed, then infers bike movements by differencing consecutive
snapshots of station occupancy.

## What the feed actually does

Measured on 25 August 2026 with `--probe`. These findings shape the whole
pipeline, and the numbers below are worth re-checking before you rely on them —
see `docs/DATA_QUALITY.md` for the full account.

| Observation | Consequence |
|---|---|
| Advertises `ttl: 60`; snapshot times are quarter-hour aligned, but only 3 distinct snapshots reached us in 38 min of polling, with a 75-min stretch of nothing new | **Effective resolution is 15 minutes at best, and irregular.** Some hours carry four observations, some one — check the `observations` column |
| Served by replicas whose caches are out of step, by as much as 90 minutes | Differencing unguarded would invent a departure and a matching arrival out of nothing. The collector stores each distinct snapshot once, keyed on identity rather than recency, so out-of-order arrivals are kept rather than discarded |
| Supports conditional GET (`If-None-Match`), including multiple ETags | An unchanged poll is a 304 with an empty body, so 30-second polling is nearly free. A row is written only when the feed advances |
| Each station carries its own `last_reported`, to the second | Changes can be timestamped precisely even though publication is coarse. This is the event clock the analysis uses |
| No `num_docks_available`; every station is `is_virtual_station` | Occupancy is measurable. Dock saturation is **not** — `capacity` is a nominal allowance |
| Network-wide, only ~31% of stations had reported within the hour; 17% silent over 24 h | A silent station looks identical to an idle one. Bern is much healthier — 68% within the hour |

## Scope

The feed covers 1,663 stations across Switzerland, but they are not one
network: Bern, Zürich, Basel, Ticino and others, hundreds of kilometres apart.
Collecting all of them and taking the centroid lands in empty countryside
between the cities, and the "nearest" weather station comes out as a rural site
representing all of them at once.

Collection is therefore scoped geographically, by distance from a city centre:

```bash
Rscript R/01_collect_publibike.R --city Bern --radius 5
```

Bern gives 272 stations, ~1,500 bikes, and the healthiest reporting rate in the
network. `--city` accepts Bern, Zurich, Basel, Fribourg, Biel, Lugano, Sion,
Aarau, Martigny, La Chaux-de-Fonds, or `--centre lat,lon` for anywhere else.

## Data model

```
station_information ──(station_id)──▶ station_status ──(hour, UTC)──▶ weather_hourly
     PubliBike                           PubliBike                      MeteoSwiss
     dimension                           fact                           dimension
                                           │
                                       poll_log
                                    collection audit
```

`poll_log` records every poll attempt, whether or not it produced data. It is
what lets the writeup say "the feed published nothing for 40 minutes" rather
than "there is a gap and we do not know why".

## Pipeline

| Script | Does |
|---|---|
| `R/01_collect_publibike.R` | Polls the GBFS feed, accumulates status history |
| `R/02_derive_flows.R` | Differences occupancy into flows; joins the station dimension |
| `R/03_fetch_meteoswiss.R` | Finds nearest weather station, downloads hourly data |
| `R/04_join_and_analyse.R` | Merges on the hour, reports the weather–demand relationship |
| `R/05_explore.R` | Exploratory analysis and the figures for the writeup |

Dependencies: `jsonlite`, and the `curl` binary (present on macOS, Linux and
GitHub runners). Everything else is base R.

## Quick start

```bash
install.packages("jsonlite")          # in R

Rscript R/01_collect_publibike.R --probe --probe-minutes 45   # measure the feed
Rscript R/01_collect_publibike.R --once --city Bern           # validate
Rscript R/02_derive_flows.R --data data --out derived
Rscript R/03_fetch_meteoswiss.R --stations derived/stations.csv --out derived
Rscript R/04_join_and_analyse.R --derived derived
Rscript R/05_explore.R --derived derived --out figures
```

`05_explore.R` is the one to run while writing up. It prints the numbers a
methods section needs — sample sizes, coverage, the wet/dry split — refuses to
fit a model on too few hours, and writes five figures to `figures/`.

Collection itself runs on GitHub Actions — see `docs/GITHUB_SETUP.md`.

## Documentation

- **`CHECKLIST.md`** — day-by-day plan for the collection week. Start here.
- `docs/DATA_QUALITY.md` — what the feed does, measured, and what it costs the analysis
- `docs/PROPOSAL.md` — summary, research questions, sources, method, limitations
- `docs/GITHUB_SETUP.md` — why the workflow is structured as it is, and how to run it

## Attribution

Bike-share data © PubliBike, via the MobiData BW GBFS republication. Weather
data © MeteoSwiss, used under their open data terms. The GBFS specification
excludes personally identifiable information; no attempt is made to link
movements to individuals.
