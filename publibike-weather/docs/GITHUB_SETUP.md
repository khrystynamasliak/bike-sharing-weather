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

1. starts a single R process that polls every 60 seconds for 5h20m,
2. commits the collected data,
3. dispatches the next run,
4. exits before the 6-hour kill.

Four runs a day instead of 1,440. Scheduling delay costs you a gap between
runs, not the sampling structure inside them. A 6-hourly cron entry sits behind
this as a watchdog in case the chain breaks.

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
Actions → "Collect PubliBike data" → Run workflow. Set the city, or leave it
blank for the whole network.

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

At one-minute polling for one city, expect roughly 1 MB per run and 7 MB per
week — trivial for a git repo. The whole network at one minute is about 36 MB
per week, still fine. Only if you ran the full network for several months would
repo size become worth thinking about.

## Retrieving the data

```bash
git clone https://github.com/YOU/YOUR-REPO.git
cd YOUR-REPO
Rscript R/02_derive_flows.R --data data --out derived
Rscript R/03_fetch_meteoswiss.R --stations derived/stations.csv --out derived
Rscript R/04_join_and_analyse.R --derived derived
```

`derived/` is gitignored — it regenerates from the raw data in seconds, so
there's no reason to version it.

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
works, longer if a dispatch fails and the watchdog has to pick it up. Those
gaps are visible in the derived events table as large `gap_minutes` values.
Filter on that column rather than treating the series as continuous, and state
the median gap and the number of interruptions in your methods section. It is a
limitation, but a documented and quantified one, which is all a marker asks.
