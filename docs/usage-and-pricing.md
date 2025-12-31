## Worker usage vs. Cloudflare pricing

This project’s cost footprint comes from the Worker that runs on a cron schedule, the KV reads/writes it performs, and any outbound `fetch` calls it makes on your behalf. The points below tie each behavior to code so you can audit or adjust it.

### 1. Cron schedule determines Worker invocations
- The only process that runs on a schedule is the cron Worker configured in `wrangler.toml:1-14`. If you leave the default `crons = ["* * * * *"]`, Cloudflare executes `processCronTrigger` once per minute, i.e., 1,440 runs/day. Each run counts as **one** Worker request regardless of how many monitors you check, because it is the same invocation looping over your config.
- Cloudflare’s free tier allows 100,000 Worker requests/day, so even the 1,440 baseline is <1.5 % of the quota. To change the cadence, edit the cron expression (e.g., `*/5 * * * *` for every five minutes) and redeploy.

### 2. Monitor count drives CPU time and subrequests, not request count
- Inside `src/functions/cronTrigger.js:32-149`, the Worker iterates over every entry in `config.monitors`. The loop makes one outbound `fetch` per monitor (lines 44-57) and, depending on status changes, may make additional `fetch` calls to Slack/Telegram/Discord (lines 72-99). These are counted as **subrequests** within the same Worker invocation.
- Cloudflare caps subrequests at 50 per invocation on current plans. Because each monitor consumes at least one `fetch`, you should stay below ~49 monitors per Worker run, which is why the README calls out “Max 25 monitors” when Slack notifications double the subrequest usage (`README.md:114`).
- More monitors also consume more of the 30 ms CPU allotment per invocation on the free/bundled plans. If you add expensive checks (e.g., lots of slow APIs), you might hit CPU limits before request limits, but that still happens inside a single invocation.

### 3. KV access scales with cron frequency, not monitor count
- Each cron run performs exactly one read (`await getKVMonitors()` at `src/functions/cronTrigger.js:21-27`) and one write (`await setKVMonitors(monitorsState)` at lines 151-156) against the `KV_STATUS_PAGE` namespace. The JSON blob already contains every monitor’s history, so adding monitors doesn’t increase KV call counts; it only increases the payload size.
- Workers KV free tier allows ~100k reads and 1k writes/day. At one cron run per minute you consume ~1,440 reads + 1,440 writes, comfortably below both limits. Halving or doubling the cron cadence linearly halves/doubles the KV usage.

### 4. Outbound traffic and incident history
- For every monitor and every run, the Worker performs at least one outbound HTTPS request (`fetch(monitor.url)` lines 44-55). That traffic hits your origins, not Cloudflare billing, but it is the knob that scales with the number of services you watch.
- Response-time collection is controlled by `settings.collectResponseTimes` (`config.yaml:5-6`). When enabled, the Worker stores per-day averages in KV (`src/functions/cronTrigger.js:101-140`), but this still happens within the same invocation.
- History retention is enforced by `settings.daysInHistogram`; the garbage-collection script trims KV data beyond that window (`src/cli/gcMonitors.js:73-83`). Larger windows keep more data in KV but do not change invocation counts.

### TL;DR
| What you change | Effect on billing/limits |
|-----------------|-------------------------|
| Cron expression | Directly changes Worker + KV request counts (1 per run). |
| Number of monitors | Increases per-run CPU time, outbound subrequests, and origin traffic, but still a single Worker request. Stay under ~49 monitors per Worker to respect subrequest limits. |
| Notifications enabled | Adds extra subrequests when status changes (Slack/Telegram/Discord). |
| `daysInHistogram` / response-time flag | Only affects KV payload size/retention, not the number of reads/writes per run. |

Need finer-grained probes or more monitors than a single invocation can handle? Split your monitors across multiple Worker scripts (each with its own cron) or move to a paid plan so higher CPU usage and KV payload sizes are less risky. All other costs remain tied to the schedule, not to the number of rows in `config.yaml`.
