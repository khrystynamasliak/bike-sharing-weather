# Collection week checklist

**Collecting:** Tue 25 Aug → Mon 31 Aug 2026 (consider extending — see the end)
**City:** Bern, 5 km radius, 272 stations · **Poll:** 30 s · **Data:** ~320 KB/day

---

## Read this first — where things stand

Collection has **not started yet**. The two runs on 24 August were both
`duration 2` test runs, and a run under 60 minutes deliberately does not chain
to a successor, so each one collected two polls and stopped. That is the
workflow behaving as designed; it just was not the run you wanted.

Three things were also found and fixed while checking the pipeline, and they
matter for what you write up:

- The feed publishes **far less often than its `ttl: 60` claims, and
  irregularly** — 38 minutes of polling yielded three distinct snapshots, with a
  75-minute stretch of nothing new. Fifteen minutes is a best case, not a
  sampling interval.
- Its replicas serve snapshots **up to 90 minutes out of step**, which would
  fabricate flow events. The collector now stores each distinct snapshot once,
  keyed on identity, so out-of-order arrivals are kept rather than thrown away.
- Every `bikes_type_*` column was **silently all zeros** — a regex bug meant the
  e-bike/classic split never worked. It does now, which makes Q3 answerable.

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

- [ ] **Create the chaining token** (skip if `COLLECTOR_PAT` already exists).
      Settings (your account) → Developer settings → Personal access tokens →
      Fine-grained tokens → Generate new token.
      - Repository access: only this repo
      - Permissions: **Actions: Read and write**, **Contents: Read and write**
      - Expiry: 30 days is fine
      Save it as a repository secret named `COLLECTOR_PAT`
      (Settings → Secrets and variables → Actions).

- [ ] **Test the feed locally first** (catches a dead URL before you wait hours):
      ```bash
      R -e 'install.packages("jsonlite", repos="https://cloud.r-project.org")'
      Rscript R/01_collect_publibike.R --once --city Bern
      ls data/station_information/   # should show a stations_*.csv
      ```
      Expect `Scope: 272 of 1663 stations within 5 km of Bern`.
      If it fails, fix it before starting the workflow. Do not skip.

- [ ] **Delete the local test data** so it does not confuse the real run:
      `rm -rf data/station_status data/station_information data/poll_log`

- [ ] **Start collection.**
      Actions tab → "Collect PubliBike data" → Run workflow →
      city `Bern`, radius `5`, interval `30`, **duration `320`**, probe `false`.

      ⚠️ **Duration must be 320.** Anything under 60 is treated as a test and
      will not chain — that is what stopped collection yesterday.

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

## Monday 31 August — stop and analyse

- [ ] **Disable the workflow.** Actions → workflow → "···" → Disable workflow.
      Don't leave it running past the deadline.

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

## One thing worth considering

Seven days gives you **one weekend** (Sat 29, Sun 30). Any weekday-vs-weekend
claim then rests on a sample of one, which is thin — a single rainy Saturday
would distort it badly.

Stretching to **Thursday 4 September (11 days)** gives you two weekends and
roughly doubles your rain exposure, at no extra cost or effort. At ~320 KB a
day the storage is irrelevant. If your deadline permits, do that. Decide on
Thursday when you see how much rain you're getting.

---

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
