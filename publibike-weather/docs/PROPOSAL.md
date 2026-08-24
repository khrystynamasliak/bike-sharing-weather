# Weather sensitivity of bike-share demand: evidence from high-frequency station data in Switzerland

**Project proposal**

---

## 1. Summary

This project measures how weather conditions affect demand for bike sharing in
Switzerland, using two independently published data sources joined on time.

The first source is **PubliBike**, Switzerland's largest docked bike-sharing
operator, which publishes real-time system state through a GBFS feed. The second is
**MeteoSwiss**, the Federal Office of Meteorology and Climatology, which publishes
hourly measurements from its SwissMetNet automatic weather station network as Open
Government Data.

A methodological constraint shapes the entire design: **PubliBike publishes no
historical trip data.** GBFS is a real-time specification that reports current
system state and retains nothing, and there is no Swiss equivalent of the trip
archives published by North American operators such as Capital Bikeshare or Citi
Bike. The project therefore constructs its own historical dataset by polling the
live feed at five-minute intervals over the collection period, then infers bike
movements by differencing consecutive snapshots of station occupancy.

This constraint is also what makes the project original. Rather than analysing a
pre-cleaned dataset that thousands of other students have used, it involves building
a data collection pipeline, reasoning about measurement error introduced by the
inference method, and validating a join between two sources that were never designed
to be combined.

---

## 2. Research questions

### Main question

**How does weather affect demand for bike sharing in Switzerland, and does the
effect differ across stations and bike types?**

This question requires both sources. Bike data alone cannot answer it; weather data
alone is meaningless without a demand series. It is falsifiable, and the magnitude
of the effect is not known in advance.

### Sub-questions

**Q1. How much does rainfall suppress ridership?**
Compare hourly network turnover in wet versus dry hours, then repeat the comparison
within commuting hours only to control for the daily demand cycle. Published studies
of bike-share ridership typically find rain reducing demand by 20–50%, providing a
benchmark against which to situate the result rather than reporting a figure in
isolation.

**Q2. Is the temperature relationship non-linear?**
Ridership generally increases with temperature up to a threshold and then declines.
Binning temperature into ranges will reveal any turning point; a linear correlation
would conceal it. Identifying where the turning point falls is a more substantive
finding than estimating a slope.

**Q3. Are e-bike users less weather-sensitive than classic-bike users?**
The GBFS `vehicle_types_available` field distinguishes the two. Hypothesis: e-bike
users are disproportionately committed commuters with fewer substitutes, so their
demand should fall less in poor conditions. This question is specific to this data
collection method — most published trip archives do not separate bike types cleanly.

**Q4. Does weather change *where* people ride, not only how much?**
Compare each station's share of total network turnover in wet versus dry hours. If
wet-weather demand concentrates near rail stations, this suggests riders switching
modes partway rather than abandoning trips entirely.

### Secondary question (fallback)

**Is dock capacity allocated where demand is?**

Plot total turnover against dock capacity per station; stations far above the fitted
line are under-docked, those far below over-docked. Combine with cumulative net flow
to identify stations that structurally drain or fill and therefore require
operational rebalancing.

This question requires only the PubliBike data. It is held in reserve because the
primary question depends on observing rainfall during the collection window. If the
period proves dry, there is no variation to analyse. Precipitation should be checked
after three to four days of collection; if it is flat, either extend collection or
pivot to this question.

---

## 3. Data sources

### Source 1 — PubliBike (private operator)

| | |
|---|---|
| Publisher | PubliBike AG |
| Access | `https://api.publibike.ch/v1/gbfs/v2/gbfs.json` |
| Standard | GBFS 2.3 |
| Authentication | None required |
| Catalogue | `github.com/MobilityData/gbfs/blob/master/systems.csv` (filter Country Code = CH) |
| Specification | `https://gbfs.org/` |

Two tables, retrieved from separate endpoints listed in the discovery document:

**`station_status`** — the fact table. One row per station per poll.
Fields: `station_id`, timestamp, `num_bikes_available`, `num_docks_available`,
`num_bikes_disabled`, `is_renting`, `is_returning`, `vehicle_types_available`.
Approximately 187,000 rows per day at five-minute polling across roughly 650
stations; about 1.3 million rows after one week.

**`station_information`** — the dimension table. One row per station.
Fields: `station_id`, `name`, `lat`, `lon`, `capacity`, `address`, `post_code`.
Approximately 650 rows, static.

*Note on network coverage:* PubliBike merged with Velospot, and the two are
published as separate feeds. PubliBike proper covers Bern, Lausanne–Morges, Nyon,
Sottoceneri and Zurich; Velospot covers Fribourg, Basel, Biel, Valais and others, at
`https://api.mobidata-bw.de/sharing/gbfs/v3/velospot_ch/gbfs`. Select the feed
matching the target city.

### Source 2 — MeteoSwiss (federal agency)

| | |
|---|---|
| Publisher | Federal Office of Meteorology and Climatology (MeteoSwiss) |
| Access | STAC API at `https://data.geo.admin.ch/api/stac/v1` |
| Collection | `ch.meteoschweiz.ogd-smn` |
| Documentation | `https://opendatadocs.meteoswiss.ch/` |
| Network | SwissMetNet automatic weather stations |

**`weather_hourly`** — hourly measurements for a selected station.
Parameters used: `tre200h0` (air temperature), `rre150h0` (precipitation),
`fkl010h0` (wind speed), `ure200h0` (relative humidity), `sre000h0` (sunshine
duration), `gre000h0` (global radiation). 168 rows per station per week.

Format characteristics documented by MeteoSwiss and handled in the code: CSVs are
encoded Windows-1252 rather than UTF-8; dates are formatted `dd.mm.yyyy HH:MM`; all
timestamps are UTC; hourly aggregates should be downloaded directly rather than
computed from 10-minute raw data, because manual corrections are applied at the
aggregated level.

### Source independence

The two sources are independent in publisher (private operator versus federal
agency), instrument (dock sensors versus meteorological equipment), licence,
publication cadence, and spatial resolution. Neither was designed with the other in
mind.

---

## 4. Data model

```
station_information  ──(station_id)──▶  station_status  ──(hour)──▶  weather_hourly
    PubliBike                              PubliBike                   MeteoSwiss
    ~650 rows                              ~1.3M rows                  168 rows/week
    dimension                              fact                        dimension
```

| Join | Key | Why it is necessary |
|---|---|---|
| status ↔ information | `station_id` | Availability counts are uninterpretable without capacity: three bikes at an eight-dock station is healthy, three at a thirty-dock station is nearly empty. Coordinates for spatial analysis exist only in this table. |
| status ↔ weather | `hour` (UTC) | Attaches conditions to demand. Both sources use UTC, so no timezone conversion is required — but the pipeline verifies overlap rather than assuming it. |

**Timestamp alignment.** MeteoSwiss hourly values are backward-looking: a timestamp
of 16:00 covers 15:10 to 16:00. Bike flows are aggregated by flooring poll times to
the hour, so a bike hour labelled 16:00 covers 16:00 to 16:59. The windows are
offset by approximately one hour. For slowly varying quantities such as temperature
this is immaterial; for rainfall it may not be. The analysis is therefore run both
with and without a one-hour shift, and sensitivity to the choice is reported.

---

## 5. Method

1. **Collect.** Poll the PubliBike GBFS feed every five minutes, appending each
   snapshot to disk. Refresh the station dimension table daily.
2. **Derive flows.** Difference consecutive occupancy readings per station.
   Negative changes are treated as departures, positive as arrivals. Changes of five
   or more bikes within one interval are flagged as likely operator rebalancing.
3. **Aggregate.** Roll up to station-hour grain: departures, arrivals, net flow,
   turnover, mean/minimum/maximum occupancy, fill rate, empty and full indicators.
4. **Fetch weather.** Identify the MeteoSwiss station nearest the bike network
   centroid by haversine distance; download its hourly series.
5. **Join and analyse.** Merge on the hour. Compare wet and dry hours descriptively,
   then estimate a linear model controlling for hour of day, weekend, and
   temperature to isolate the rainfall effect.

---

## 6. Limitations

**Stock rather than flow.** The feed reports how many bikes are at a station, not
individual rides. Departures and arrivals are inferred by differencing, so a bike
leaving and another arriving between two polls nets to zero and is invisible. This
undercounts activity, and undercounts it most at the busiest stations — a systematic
bias rather than random noise. The magnitude can be estimated by collecting at
one-minute intervals for a period and comparing against the same data downsampled to
five minutes.

**Limited observation window.** The dataset spans only the collection period. A week
supports weekday–weekend comparison; two weeks is preferable. Whether sufficient
rainfall occurs is a matter of chance.

**Confounding.** Temperature and hour of day both peak in mid-afternoon, so raw
correlation between temperature and ridership largely reflects the daily activity
cycle rather than a weather effect. The analysis controls for hour of day; results
without this control are reported only as descriptive.

**Single weather station.** One station represents conditions across the whole
network. This is defensible for compact urban networks but becomes questionable
across larger areas, particularly for precipitation, which MeteoSwiss notes exhibits
high spatial variability.

**Rebalancing contamination.** Operator van movements appear in the data as bike
count changes indistinguishable in kind from rider activity. The five-bike threshold
is a heuristic, not a certainty; results are reported both with and without flagged
events.

---

## 7. Ethics and attribution

Both sources are cited: PubliBike for system data, MeteoSwiss for meteorological
data, subject to their respective terms of use. The GBFS specification deliberately
excludes personally identifiable information, so the data contains no individual-level
records, and no attempt is made to link bike movements to individuals. Polling is
conducted at five-minute intervals — well within reasonable use, and above the
30-second refresh floor the specification itself contemplates.

---

## 8. Implementation

Pipeline written in R. Dependencies: `jsonlite` for JSON and STAC API access;
everything else uses base R.

| Script | Purpose |
|---|---|
| `01_collect_publibike.R` | Polls the GBFS feed; accumulates status history |
| `02_derive_flows.R` | Differences the stock series into flows; joins the station dimension |
| `03_fetch_meteoswiss.R` | Locates the nearest weather station; downloads hourly data |
| `04_join_and_analyse.R` | Merges the two sources on the hour; reports the relationship |

```r
install.packages("jsonlite")

# Validate the feed and take one snapshot
Rscript 01_collect_publibike.R --once

# Begin continuous collection (leave running)
Rscript 01_collect_publibike.R --interval 300 --city Bern

# After several days
Rscript 02_derive_flows.R --data data --out derived
Rscript 03_fetch_meteoswiss.R --stations derived/stations.csv --list
Rscript 03_fetch_meteoswiss.R --stations derived/stations.csv --out derived
Rscript 04_join_and_analyse.R --derived derived
Rscript 04_join_and_analyse.R --derived derived --shift-weather 1   # sensitivity check
```
