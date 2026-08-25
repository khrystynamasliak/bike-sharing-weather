# Running the collector on GitHub Actions

You can host the whole collection on GitHub for free, with no server and no
laptop left running. This document covers how, and — more importantly — the
constraints that make the obvious approach fail.

## Why not just schedule it every 5 minutes

Because it will not run. GitHub's `schedule:` trigger is best-effort: runs are
delayed under load, sometimes skipped entirely, and the minimum interval is
5 minutes anyway. Someone maintaining a public monitoring repo measured a
`*/5 * * * *` job firing 97 times out of ~2,016 slots in a week — roughly 5%,
which works out to one run every 104 minutes instead of every five.

For most cron uses that's an annoyance. For this project it's fatal: your
sampling interval *is* your measurement instrument, and an irregular, mostly-
missing one destroys the flow inference.

## What works instead

Run **one long job that polls internally**. GitHub-hosted jobs can run up to
6 hours, so the workflow:

1. starts a single R process that polls every 30 seconds for 5h20m,
2. commits the collected data,
3. dispatches the next run,
4. exits before the 6-hour kill.

Four runs a day instead of 1,440. Scheduling delay costs you a gap between
runs, not the sampling structure inside them. A 6-hourly cron entry sits behind
this as a watchdog in case the chain breaks.

**Why 30 seconds when the feed only publishes every 15 minutes?** Because an
unchanged poll is a conditional GET returning `304` with an empty body — it
costs nothing. Polling that often means each new snapshot is captured within
about half a minute of appearing, instead of up to fifteen minutes late, and
the collector writes a row only when the feed's own `last_updated` advances.
See `docs/DATA_QUALITY.md`.

## Setup

**1. Make the repository public.**
Public repos get unlimited Actions minutes. The free private allowance of
2,000 minutes/month would be gone in about three days — this workflow uses
roughly 1,440 minutes a day. If your work must stay private, collect the data
in a public repo and keep the analysis in a private one.

**2. Push the project.**

```
your-repo/
├── .github/workflows/collect.yml
├── R/
│   ├── 01_collect_publibike.R
│   ├── 02_derive_flows.R
│   ├── 03_fetch_meteoswiss.R
│   └── 04_join_and_analyse.R
├── .gitignore
└── data/            <- created by the workflow
    ├── station_information/
    ├── station_status/
    └── poll_log/    <- every poll attempt, for the methods section
```

**3. Allow the workflow to commit.**
Settings → Actions → General → Workflow permissions →
**Read and write permissions**.

**4. Create the chaining token.**
Settings → Developer settings → Personal access tokens → Fine-grained tokens.
Scope it to this repository with **Actions: read and write** and
**Contents: read and write**. Save it as a repository secret named
`COLLECTOR_PAT` (Settings → Secrets and variables → Actions).

This step is not optional if you want continuous collection. A
`workflow_dispatch` triggered by the default `GITHUB_TOKEN` does not start a
new workflow run — GitHub blocks that to prevent runaway recursion. Without the
PAT, the chain stops after one run and you fall back to the delayed watchdog.

**5. Start it.**
Actions → "Collect PubliBike data" → Run workflow. Set city `Bern` and leave
**duration at 320**.

A duration under 60 minutes is treated as a test run and deliberately does
*not* dispatch a successor — otherwise every experiment would start an endless
chain. That safety is what stopped the 24 August runs after two polls each. The
job summary on every run states plainly whether it chained.

Leaving the city blank collects all 1,663 Swiss stations, which spans four
cities hundreds of kilometres apart and makes the single-weather-station join
meaningless. Only do that if you intend to split by city afterwards.

**6. Stop it when you have enough data.**
Actions → the workflow → "..." → Disable workflow. It will otherwise run
indefinitely.

## Checking it is working

Within about ten minutes of starting, the Actions tab should show a run in
progress, and `data/station_status/` should gain a file after the first commit
(roughly 5.5 hours in). Check again the next morning: you should see four or
five commits, and the file count should keep growing.

The failure mode to guard against is silent death. GitHub does not notify you
when a scheduled run stops happening. Look at the repo once a day for the first
few days.

## Storage

Each run writes its own tagged file (`status_20260824T0917Z.csv.gz`) rather
than appending to a shared one. This matters for git: a file that is created
once and never modified adds its size to history once. A file that grows and is
recommitted daily adds its full size every day.

Because a row is written per *publication* rather than per poll, volume is set
by the feed, not by the poll interval. The Bern network (272 stations) produces
about 96 snapshots a day at ~3.3 KB gzipped each — roughly **320 KB a day, or
2.5 MB for a week**. Even eleven days of the whole 1,663-station network would
stay under 25 MB.

Writing every poll instead, as the first version did, would have been ~28 MB a
day for the whole network — about 200 MB a week of near-duplicate rows.

## Retrieving the data

```bash
git clone https://github.com/YOU/YOUR-REPO.git
cd YOUR-REPO
Rscript R/02_derive_flows.R --data data --out derived
Rscript R/03_fetch_meteoswiss.R --stations derived/stations.csv --out derived
Rscript R/04_join_and_analyse.R --derived derived
```

`derived/` **is** committed, by the "Analyse collected data" workflow, so the
tables are readable on GitHub without cloning and running R. It regenerates
from `data/` in seconds, so treat it as output rather than source: if the two
ever disagree, `data/` wins.

## Honest comparison with the alternatives

| Option | Cost | Reliability | Effort |
|---|---|---|---|
| GitHub Actions (this) | Free | Good, with gaps between runs | Medium — PAT setup is fiddly |
| Free cloud VM (e.g. Oracle Cloud always-free tier) | Free | Best — genuinely continuous | Medium — one-time VM setup |
| University server | Free | Best, if you have access | Low — ask IT, then `tmux` |
| Your laptop | Free | Poor — sleep, reboots, wifi | Lowest |
| Small VPS (~5 CHF/month) | Paid | Best | Low |

If you have access to a university machine, use it — `tmux` plus one command
beats all of this. GitHub Actions is the best option when you don't, and it has
a genuine side benefit: the collection is version-controlled, timestamped and
publicly auditable, which is a reproducibility point worth a sentence in your
methodology.

## One caveat for your writeup

This approach produces small gaps between runs — a few minutes if the chain
works, longer if a dispatch fails and the watchdog has to pick it up.

You can now say exactly how long those gaps were, rather than inferring them.
`data/poll_log/` records every poll attempt with its outcome, so
`02_derive_flows.R` can separate two things that look identical in the status
series: minutes where the collector was not running, and minutes where it was
running and the feed simply had nothing new. Report the first as collection
downtime and the second as the feed's publication cadence. That distinction is
worth more in a methods section than a single gap statistic.
