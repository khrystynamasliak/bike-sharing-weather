# Collection week checklist

**Collecting:** Mon 24 Aug → Mon 31 Aug 2026
**City:** Bern · **Interval:** 60 seconds · **Expected data:** ~7 MB

---

## Today — Monday 24 August (about 30 minutes)

- [ ] **Create a PUBLIC repo** on GitHub, e.g. `publibike-weather`.
      Public matters: private repos get 2,000 Actions minutes/month and this
      uses ~1,440 a day.

- [ ] **Push this project.** From the unzipped folder:
      ```bash
      git init && git add . && git commit -m "Initial: collection pipeline"
      git branch -M main
      git remote add origin https://github.com/YOU/publibike-weather.git
      git push -u origin main
      ```

- [ ] **Enable write permissions.**
      Settings → Actions → General → Workflow permissions →
      **Read and write permissions** → Save.

- [ ] **Create the chaining token.**
      Settings (your account) → Developer settings → Personal access tokens →
      Fine-grained tokens → Generate new token.
      - Repository access: only `publibike-weather`
      - Permissions: **Actions: Read and write**, **Contents: Read and write**
      - Expiry: 30 days is fine
      Copy the token.

- [ ] **Save it as a secret.**
      Repo → Settings → Secrets and variables → Actions → New repository secret.
      Name: `COLLECTOR_PAT`. Value: the token.

- [ ] **Test the feed locally first** (catches a dead URL before you wait 6 hours):
      ```bash
      R -e 'install.packages("jsonlite", repos="https://cloud.r-project.org")'
      Rscript R/01_collect_publibike.R --once --city Bern
      ls data/station_information/   # should show a stations_*.csv
      ```
      If this fails, fix it before starting the workflow. Do not skip.

- [ ] **Start collection.**
      Actions tab → "Collect PubliBike data" → Run workflow →
      city `Bern`, interval `60` → Run.

- [ ] **Confirm it's running.** Within 2 minutes a run should appear with a
      spinning amber dot. Open it, check the "Collect for 5h30m" step is
      logging polls.

- [ ] **Delete the local test data** so it doesn't confuse things later:
      `rm -rf data/`

---

## Tomorrow — Tuesday 25 August ⚠️ THE IMPORTANT ONE

This is the most valuable half-hour of the week. **Run the entire pipeline on
partial data.** If something is broken, you find out with six days left to fix
it, not on the morning of the deadline.

- [ ] Check the repo: there should be **3–4 commits** from
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
      - [ ] Derive reports a sensible station count (Bern ≈ 100–170)
      - [ ] Weather station list shows BER or similar, within a few km
      - [ ] The join reports **overlap > 0** — this is the one that fails silently
      - [ ] The hourly turnover chart shows a plausible daily shape

- [ ] If the join reports zero overlap, try `--shift-weather 1`, and check the
      weather file isn't the historical archive.

- [ ] **Note the gap statistics.** In `derived/events.csv`, look at
      `gap_minutes`. Median should be ~1. A few large values are the handovers
      between Actions runs — expected, and you'll report them.

---

## Wednesday 26 August (5 minutes)

- [ ] Has it rained? `derived/weather_hourly.csv`, column `precip_mm`.
- [ ] **If precipitation is essentially zero so far** → plan to extend
      collection to ~11 days rather than 7. No rain means no primary finding.
- [ ] Confirm commits are still arriving (the chain hasn't silently died).

---

## Friday 28 August (5 minutes)

- [ ] Commits still arriving? Roughly 16–20 by now.
- [ ] `du -sh data/` — should be around 4–5 MB.
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
      - Number of stations
      - Total status observations
      - Median and maximum `gap_minutes`, and number of gaps > 5 min
      - Number of wet hours vs dry hours
      - Whether the shift-weather sensitivity check changed the conclusion

---

## One thing worth considering

Seven days gives you **one weekend** (Sat 29, Sun 30). Any weekday-vs-weekend
claim then rests on a sample of one, which is thin — a single rainy Saturday
would distort it badly.

Stretching to **Thursday 4 September (11 days)** gives you two weekends and
roughly doubles your rain exposure, at no extra cost or effort. If your
deadline permits, do that. Decide on Wednesday when you see how much rain
you're getting.

---

## If something breaks

| Symptom | Likely cause | Fix |
|---|---|---|
| No runs appear | Workflow not on default branch | Ensure `collect.yml` is on `main` |
| Runs but doesn't commit | Workflow permissions | Settings → Actions → Read and write |
| Only one run, then stops | `COLLECTOR_PAT` missing/expired | Recreate the secret; re-run manually |
| Feed error in logs | PubliBike URL changed | Check `systems.csv` in the MobilityData repo, filter CH |
| Join overlap = 0 | Historical weather file, or timing | Re-fetch without `--historical`; try `--shift-weather 1` |
| Very few events derived | Interval too coarse, or wrong city | Check station count and `gap_minutes` |

Anything else — paste the error output and I'll debug it.
