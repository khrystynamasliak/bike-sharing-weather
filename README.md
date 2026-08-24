# Weather sensitivity of bike-share demand in Switzerland

Measuring how weather affects PubliBike demand, using two independently
published data sources joined on time.

**Status:** collecting 24–31 August 2026 · Bern network · 60-second polling

---

## The two data sources

| | Source 1 | Source 2 |
|---|---|---|
| Publisher | PubliBike (private operator) | MeteoSwiss (federal agency) |
| Data | Station occupancy, per minute | Weather, per hour |
| Access | GBFS feed, `api.publibike.ch` | STAC API, `data.geo.admin.ch` |
| Collection | Self-collected — no history is published | Downloaded |

PubliBike publishes **no historical trip data** — GBFS reports current system
state and retains nothing. This project therefore builds its own history by
polling the live feed, then infers bike movements by differencing consecutive
snapshots of station occupancy.

## Data model

```
station_information ──(station_id)──▶ station_status ──(hour, UTC)──▶ weather_hourly
     PubliBike                           PubliBike                      MeteoSwiss
     dimension                           fact                           dimension
```

## Pipeline

| Script | Does |
|---|---|
| `R/01_collect_publibike.R` | Polls the GBFS feed, accumulates status history |
| `R/02_derive_flows.R` | Differences occupancy into flows; joins station dimension |
| `R/03_fetch_meteoswiss.R` | Finds nearest weather station, downloads hourly data |
| `R/04_join_and_analyse.R` | Merges on the hour, reports the weather–demand relationship |

Dependencies: `jsonlite`. Everything else is base R.

## Quick start

```bash
install.packages("jsonlite")          # in R

Rscript R/01_collect_publibike.R --once --city Bern        # validate
Rscript R/02_derive_flows.R --data data --out derived
Rscript R/03_fetch_meteoswiss.R --stations derived/stations.csv --out derived
Rscript R/04_join_and_analyse.R --derived derived
```

Collection itself runs on GitHub Actions — see `docs/GITHUB_SETUP.md`.

## Documentation

- **`CHECKLIST.md`** — day-by-day plan for the collection week. Start here.
- `docs/PROPOSAL.md` — summary, research questions, sources, method, limitations
- `docs/GITHUB_SETUP.md` — why the workflow is structured as it is, and how to run it

## Attribution

Bike-share data © PubliBike. Weather data © MeteoSwiss, used under their open
data terms. The GBFS specification excludes personally identifiable
information; no attempt is made to link movements to individuals.
