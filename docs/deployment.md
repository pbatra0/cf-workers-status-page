## Deployment quickstart

This project still uses Wrangler v1.x and a KV-backed Flareact site. Use the GitHub Actions workflow in `.github/workflows/deploy.yml` for reproducible deploys.

### Required setup

1. **Cloudflare account:** make sure Workers are enabled and note your `CF_ACCOUNT_ID`.
2. **API token:** create a token with `Workers Scripts:Edit` and `Workers KV Storage:Edit`. Save it as the `CF_API_TOKEN` repository secret.
3. **Repository secrets:** add the following in _Settings → Secrets and variables → Actions_:
   - `CF_API_TOKEN`
   - `CF_ACCOUNT_ID`
4. **Config:** edit `config.yaml` with your monitors and status-page metadata.

### Deploy workflow

Push to `main` or trigger the “Deploy” workflow manually. The action step:

- installs Wrangler 1.19.8 inside CI
- ensures the `KV_STATUS_PAGE` namespace exists (reuses it if already created)
- injects the namespace ID into `wrangler.toml` for the publish command
- exports `KV_NAMESPACE_ID` so post-deploy cleanup (`yarn kv-gc`) can talk to KV

The workflow publishes the Worker and static assets, then runs a garbage-collection script that trims monitor history to match `settings.daysInHistogram`.

### How the application works

- **Cron-driven health checks:** `src/functions/cronTrigger.js` is wired to a Cloudflare Cron Trigger (`wrangler.toml:11`). Every minute the Worker iterates over `config.yaml` monitors, performs HTTP checks, records response time metadata, and updates `KV_STATUS_PAGE`.
- **Status persistence:** Monitor state lives in Workers KV under the key `monitors_data_v1_1`. `getKVMonitors`/`setKVMonitors` read and write this JSON blob so both the cron Worker and the Flareact frontend see the same data.
- **Notifications (optional):** When a monitor flips state, the Worker conditionally calls `notifySlack/Telegram/Discord` if the corresponding secrets exist.
- **Static frontend:** Flareact builds a static bundle (`yarn build`) that Wrangler uploads via Workers Sites. The Worker serves both the API endpoints and the pre-rendered UI from KV.
- **Workflow runs:** Each GitHub Actions run executes `yarn build`, publishes the Worker, then executes `yarn kv-gc` to prune stale monitor history from KV based on your configured retention.

### Optional notifications (Slack, Discord, Telegram)

The Worker supports Slack, Discord, and Telegram alerts. Each integration is disabled unless its secrets are populated:

| Integration | Required secrets | Notes |
|-------------|------------------|-------|
| Slack | `SECRET_SLACK_WEBHOOK_URL` | Incoming webhook URL |
| Discord | `SECRET_DISCORD_WEBHOOK_URL` | Incoming webhook URL |
| Telegram | `SECRET_TELEGRAM_API_TOKEN`, `SECRET_TELEGRAM_CHAT_ID` | Bot token + chat ID |

Add any you need as GitHub secrets—the workflow automatically exposes them to the Worker. If you do _not_ want an integration, simply leave the corresponding secrets undefined; the Worker checks for real values before sending notifications.

#### Slack
1. In Slack, navigate to **Apps → Manage → Custom Integrations → Incoming Webhooks** and create a webhook for the channel you want alerts in.
2. Copy the webhook URL and store it as the `SECRET_SLACK_WEBHOOK_URL` repository secret.
3. Deploy. Whenever a monitor flips state, the Worker posts a message with the monitor name, HTTP method + URL, and a direct link to your status page.

#### Discord
1. In your Discord server, create a webhook under **Server Settings → Integrations → Webhooks**.
2. Copy the URL and add it as `SECRET_DISCORD_WEBHOOK_URL`.
3. Deploy. Status changes appear as rich embeds with colored status indicators and a link to the status page.

#### Telegram
1. Talk to [@BotFather](https://t.me/botfather) to create a bot and obtain the API token.
2. Send a message to the bot from the Telegram account or group that should receive alerts.
3. Fetch the chat ID using `curl "https://api.telegram.org/bot<API_TOKEN>/getUpdates" | jq '.result[0].message.chat.id'`.
4. Store the token and chat ID as `SECRET_TELEGRAM_API_TOKEN` and `SECRET_TELEGRAM_CHAT_ID`.
5. Deploy. The Worker sends Markdown-formatted messages that include the monitor name, status, HTTP request, and link to your status page.

No additional code changes are required—the Worker auto-detects which secrets exist and only sends notifications for the configured channels.

### Adjusting update frequency

Cron cadence is defined in `wrangler.toml` under `[triggers]`:

```toml
[triggers]
crons = ["* * * * *"]
```

Update the cron expression and redeploy to change how often the Worker runs. Wrangler uses standard crontab syntax.

Common examples:

| Interval | Cron expression |
|----------|-----------------|
| Every 1 minute (default) | `* * * * *` |
| Every 2 minutes (Workers Free tier limit) | `*/2 * * * *` |
| Every 5 minutes | `*/5 * * * *` |
| Hourly at minute 0 | `0 * * * *` |
| Daily at 07:30 UTC | `30 7 * * *` |

No changes are required in `deploy.yml`; the workflow simply publishes whatever cron schedule is present in `wrangler.toml`. After editing the cron array, push to `main` (or rerun the workflow) so Cloudflare applies the new frequency.

#### Impact on usage and the free tier (NOT VERIFIED)

Each cron tick counts exactly like any other Worker invocation: it consumes one request from your Workers quota and executes the logic that performs HTTP checks plus KV reads/writes. Increasing the frequency:

- **Improves freshness** (issues are detected sooner).
- **Raises platform usage** (more Worker invocations + more KV activity + more outbound monitor requests).

On the Workers Free plan (currently 100,000 requests/day and Cron limited to once per minute), running every 2 minutes results in ~720 invocations/day, which easily fits the quota. Switching to every minute doubles that to ~1,440 invocations/day—still safe, but keep in mind any additional traffic (manual visits to the status page) also counts against the limit.

Workers KV free tier allows roughly 100k reads and 1k writes per day. Each cron run performs 1 read + 1 write to the namespace, so a 2-minute schedule uses ~720 reads/writes daily, while a 1-minute schedule uses ~1,440 reads/writes—well within the limit, but aggressive cadences (e.g., every 10 seconds) would quickly exceed free allocation and are not permitted by Cron triggers anyway.

If you need sub-minute checks or anticipate more monitors/traffic, consider upgrading to the Bundled plan so you get higher request quotas and predictable billing.
