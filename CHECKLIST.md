# Collection week checklist

**Collecting:** Mon 24 Aug → **Thu 3 Sep 2026** (extended by one week on 27 Aug)
**City:** Bern, 5 km radius, 272 stations · **Poll:** 30 s · **Data:** ~320 KB/day

---

## Read this first — where things stand

**Collection is running and has been since 24 August, 19:01 UTC.** Three runs so
far, all started by the 6-hourly schedule. You have roughly 13.5 hours of the
whole Swiss network, and a run is in progress now.

The raw files look enormous (13 MB, 1.03M rows) because the old collector wrote
one row per poll while the feed only publishes every ~15 minutes: **93.5% of
those rows are the same snapshot re-recorded.** After de-duplication there are
41 genuine snapshots. `02_derive_flows.R` does that automatically.

Four things were found and fixed, and they matter for what you write up:

- The feed publishes **far less often than its `ttl: 60` claims, and
  irregularly** — 38 minutes of polling yielded three distinct snapshots, with a
  75-minute stretch of nothing new. Fifteen minutes is a best case, not a
  sampling interval.
- Its replicas serve snapshots **up to 90 minutes out of step**, which would
  fabricate flow events. The collector now stores each distinct snapshot once,
  keyed on identity, so out-of-order arrivals are kept rather than thrown away.
- Every `bikes_type_*` column was **silently all zeros** — a regex bug meant the
  e-bike/classic split never worked. It does now, which makes Q3 answerable.
- The data already collected carries the replica artifact (3.9% of polls
  returned to a state already seen). It is **recovered automatically** — no need
  to discard it or recollect.

`docs/DATA_QUALITY.md` has the measurements behind all three.

---

## Today — Tuesday 25 August (about 20 minutes)

- [ ] **Push the current state.** The scripts, workflow and docs have changed.

- [ ] **Confirm the repo is PUBLIC.**
      Public matters: private repos get 2,000 Actions minutes/month and this
      uses ~1,440 a day.

- [ ] **Enable write permissions.**
      Settings → Actions → General → Workflow permissions →
      **Read and write permissions** → Save.

- [ ] ~~Create the chaining token~~ **No longer needed.** You never set
      `COLLECTOR_PAT`, which is why the chaining step did nothing and every run
      came from the schedule — leaving a 93-minute gap between the first two
      runs. The schedule now fires every 5 hours instead of 6, so a successor is
      always queued before the current 5h20m run ends and the concurrency group
      starts it on handover. No secret, nothing to expire.

- [ ] **Test the feed locally first** (catches a dead URL before you wait hours):
      ```bash
      R -e 'install.packages("jsonlite", repos="https://cloud.r-project.org")'
      Rscript R/01_collect_publibike.R --once --city Bern
      ls data/station_information/   # should show a stations_*.csv
      ```
      Expect `Scope: 272 of 1663 stations within 5 km of Bern`.
      If it fails, fix it before starting the workflow. Do not skip.

- [ ] **Do NOT delete `data/`.** It holds 13.5 hours of real collection,
      including every one of the 272 Bern stations. If you ran the local test
      above, remove only what it wrote: `git checkout -- data/ && git clean -fd data/`

- [ ] **Switch the run to Bern.**
      Actions tab → "Collect PubliBike data" → Run workflow →
      city `Bern`, radius `5`, interval `30`, **duration `320`**, probe `false`.

      It will sit as *pending* until the run currently in progress finishes —
      that is the concurrency group doing its job, not a fault.

      ⚠️ **Duration must be 320.** Anything under 60 is treated as a test and
      does not chain.

      Nothing is lost by switching: all 272 Bern stations are already in the
      collected history, and `02_derive_flows.R` keeps their past rows while
      dropping the other cities. Pass `--all-stations` if you ever want the
      nationwide view back.

- [ ] **Confirm it is running and chaining.** Within 2 minutes a run should
      appear. Open it and check:
      - the "Preflight" step lists the endpoints
      - the "Collect" step logs `Snapshot 1 written`
      - at the end, the **job summary** says `Chained a successor | yes`

      The job summary is the thing to check daily. If it ever says `no`, the
      chain is dead and only the 6-hourly watchdog will restart it.

---

## Tomorrow — Wednesday 26 August ⚠️ THE IMPORTANT ONE

The most valuable half-hour of the week. **Run the entire pipeline on partial
data.** If something is broken, you find out with five days left to fix it, not
on the morning of the deadline.

- [ ] Check the repo: there should be **4–5 commits** from
      `github-actions[bot]`, and files in `data/station_status/`.

- [ ] Pull and run everything:
      ```bash
      git pull
      Rscript R/02_derive_flows.R --data data --out derived
      Rscript R/03_fetch_meteoswiss.R --stations derived/stations.csv --list
      Rscript R/03_fetch_meteoswiss.R --stations derived/stations.csv --out derived
      Rscript R/04_join_and_analyse.R --derived derived
      ```

- [ ] Verify each of these:
      - [ ] Derive reports **272 stations**; note how many snapshots per day you
            actually get (96 would be the 15-minute best case — expect fewer)
      - [ ] The de-duplication line reports **0 duplicates** (anything else means
            two collectors overlapped)
      - [ ] `already_recorded` appears in the poll-log breakdown — that is the
            replica de-duplication working, and a high share is normal
      - [ ] Station liveness shows **~65–70% reporting within 1 h** — if this
            collapses, the network went down, not your collector
      - [ ] Vehicle types report **non-zero** ebike and mbike totals
      - [ ] Weather station list shows **BER** within a few km, and the spread
            warning does **not** appear
      - [ ] The join reports **overlap > 0** — this is the one that fails silently
      - [ ] The hourly turnover chart shows a plausible daily shape

- [ ] If the join reports zero overlap, try `--shift-weather 1`, and check the
      weather file is not the historical archive.

- [ ] **Note the gap statistics** from the poll-log section of
      `02_derive_flows.R`. You want: polls made, how many were `unchanged`
      (expected: the large majority), and total minutes where polling itself
      stopped. That last number is your collection downtime — everything else
      is the feed not publishing, which is a different thing and worth saying.

---

## Thursday 27 August (5 minutes)

- [ ] Has it rained? `derived/weather_hourly.csv`, column `precip_mm`.
- [ ] **If precipitation is essentially zero so far** → plan to extend
      collection to ~11 days rather than 7. No rain means no primary finding.
- [ ] Job summary still says `Chained a successor | yes`?

## Saturday 29 August (5 minutes)

- [ ] Commits still arriving? Roughly 4 a day.
- [ ] `du -sh data/` — should be around 1.5 MB.
- [ ] Re-run the pipeline; sanity-check the numbers are growing sensibly.

---

## Thursday 3 September — stop and analyse

- [ ] **Disable the workflow.** Actions → workflow → "···" → Disable workflow.
      Nothing switches collection off by itself — its cron has no end date,
      unlike the analysis schedule. This is the one manual step that matters.

- [ ] Final pull and full run:
      ```bash
      git pull
      Rscript R/02_derive_flows.R --data data --out derived
      Rscript R/03_fetch_meteoswiss.R --stations derived/stations.csv --out derived
      Rscript R/04_join_and_analyse.R --derived derived
      Rscript R/04_join_and_analyse.R --derived derived --shift-weather 1
      ```

- [ ] Record these for your methods section:
      - Collection window (first and last timestamp)
      - Number of stations, and how many were silent for the whole window
      - Total status observations and number of distinct snapshots
      - Median and maximum interval between snapshots
      - Polling downtime in minutes, from the poll log
      - Share of events timestamped from `last_reported` vs the snapshot
      - Number of `already_recorded` responses (duplicate snapshots suppressed)
      - Distribution of the `observations` column — how many station-hours rest
        on a single reading rather than four
      - Number of wet hours vs dry hours
      - Whether the shift-weather sensitivity check changed the conclusion

---

## Where the extra week gets you

Collection was extended on 27 August and now runs to **Thursday 3 September**.

That buys the weekend of **29–30 August** — which the original window also had,
but only just, and losing it to a chain failure would have cost the whole
weekday/weekend comparison. It also roughly doubles the chances of catching rain
during daylight, which is the one thing Q1 is waiting for: as of 27 August only
3 of the wet hours collected fall between 07:00 and 21:00.

**If you want a second weekend**, run to **Sunday 6 September** instead — add
`4,5,6` to the September cron in `analyse.yml`. Two weekends turns a
weekday/weekend claim from a sample of one into a sample of two, which is the
difference between an observation and a finding. Collection itself needs no
change either way.

Storage is not a constraint: the Bern network produces about **313 KB a day**,
so another week adds roughly 2 MB to a 22 MB repository.

## If something breaks

| Symptom | Likely cause | Fix |
|---|---|---|
| Ran once, then stopped | `duration` under 60 = test run, does not chain | Re-run with duration `320` |
| No runs appear | Workflow not on default branch | Ensure `collect.yml` is on `main` |
| Runs but doesn't commit | Workflow permissions | Settings → Actions → Read and write |
| Chain dies after one run | `COLLECTOR_PAT` missing/expired | Recreate the secret; job summary names this |
| Feed error in logs | Feed URL changed | `--inspect`; check `systems.csv` in the MobilityData repo, filter CH |
| `already_recorded` on most non-304 polls | Replicas re-serving snapshots you have | Normal and harmless — the de-duplication is doing its job |
| Long stretches with nothing written | Feed stalled upstream | Confirmed behaviour, not your collector — the poll log proves it. See `docs/DATA_QUALITY.md` §1 |
| Nothing written for hours | Feed stopped publishing | Check the poll log: `unchanged` means it is up and static |
| Join overlap = 0 | Historical weather file, or timing | Re-fetch without `--historical`; try `--shift-weather 1` |
| Weather station is far away | Collecting more than one city | Use `--city Bern`, not the whole network |
| Very few events derived | Expected — 15 min resolution nets out short trips | See `docs/DATA_QUALITY.md` §1 |

Anything else — paste the error output and I'll debug it.
