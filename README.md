# Searchdesk

Searchdesk is a self-hostable Rails application for small businesses tracking their visibility in Google. The owner signs in, adds keywords and chooses sources. A separate server process collects authorised data and prepares actions after the browser closes.

## Continue development with Claude or Codex

Open the `Searchdesk` folder as the project. On the owner's Mac, you can open it in Finder with `open "$HOME/Documents/ChatGPT/Searchdesk"`. Both agents use the [shared project instructions](AGENTS.md). The [development handoff](docs/HANDOFF.md) maps dashboard features to their Rails code and regression tests.

For the original design decisions, see the [product specification](docs/design/Small-business-SEO-product-specification.pdf), its [editable copy](docs/design/Small-business-SEO-product-specification.docx) and the [dashboard prototype](docs/design/SEO-dashboard-prototype.html). These are historical design references.

For a fresh conversation, copy this prompt and fill in the task.

> Read AGENTS.md and docs/HANDOFF.md. My next Searchdesk task is [describe what the owner should be able to do]. Implement it in this working copy and verify the owner-facing result.

## Start on a Mac

With Docker Desktop running, double-click **Start.command**. On Linux or in a Mac terminal, run `bin/start` from this directory. The first start downloads the official images, generates local secrets, migrates PostgreSQL and starts the web server and job worker. Open [Searchdesk locally](http://localhost:3038).

For the existing SkinHampshire installation, sign in with your usual account and select the site in the workspace menu. For a new installation, use these steps.

1. Choose **Create an account** from the sign-in screen.
2. To explore immediately, select **Demo** on the setup screen and create the site. Its sample business has five fictional keywords with seven days of observations on two devices.
3. For your own business, create a separate site from **Workspace → Set up a site**. Use manual mode for imported observations, or managed collection after configuring the provider. **Integrations** shows the available methods and the worker's health.
4. In **Rankings**, choose a device and open a keyword to see the observed dates, winning page and history. **Actions** links each recommendation to the evidence that triggered it.

The app listens on the local loopback interface. To change the port, set both `LOCAL_PORT` and `APP_HOST` in `.env` and restart. Use the same hostname when signing in and configuring OAuth. Docker keeps database and local mail volumes between launches. `docker compose stop` stops the app. `bin/start` starts it again. Scheduled jobs need Docker and the host to be awake. A missed collection remains identifiable on the dashboard.

## Visibility overview and site audit

The **Overview** opens after sign-in. Choose a keyword and scan date to inspect Local Falcon’s street map, north-up rank grid and coordinates. Searchdesk reads completed reports through the existing connection. The trend compares saved scans of the same keyword and grid. With Search Console connected, the clicks and impressions chart uses final daily values for the last reported 28-day period. Its gaps indicate days Google omitted. The organic rank chart shows the selected device and links to the individual keywords.

**Site audit → Run crawl** checks up to 20 public URLs on the selected site. The worker reads robots.txt, follows internal page links and records affected pages and suggested fixes. The owner can enable a weekly refresh. Any member can open saved results, compare crawl dates and see submitted sitemap errors, warnings, and search performance from a matching Google property. Google's own Crawl Stats report is linked separately. The public crawl works without a Google or Ahrefs account.

## Schedules

Open **Schedules** from the main navigation for the selected site. Each row shows the frequency, the last recorded run or result, and when work next becomes eligible. Follow a row to its settings or report. Searchdesk uses the site's time zone and labels dates supplied by a provider. Local Falcon runs its own campaigns and Searchdesk imports their results separately. The page uses saved records, so opening it does not start a crawl, buy a rank check or send a model request. Owners can expand the background checks to see when the server last completed each scheduling or maintenance job.

## How tracking works

A keyword gets a separate series per source, location, device, language and measurement method. The first comparable observation fixes the baseline. The dashboard compares today's observed organic position with that baseline. An absent reading has no numeric delta. A verified top 30 without the site means **Outside 30**. Short result sets without enough evidence remain incomplete. Each row also records which page ranked. A preferred-page mismatch or two consecutive materially lower positions can open an evidence-linked action.

Rails and Solid Queue share one PostgreSQL database in this implementation. The web service, worker, scheduler and dispatcher use one application image. The scheduler checks due slots every five minutes and targets 08:00 in each site's reporting time zone. Newly enrolled keywords have a slot immediately. Submissions have a durable correlation key and quota reservation. Polling can resume after restart. Unconfirmed submissions are held for reconciliation. Closing the browser leaves these processes running.

## Connections

| Capability | How to use it |
| --- | --- |
| Manual organic ranks | On a manual site, open the keyword and choose **Import observation**. The form gives a scoped JSON example. The server validates the capture date, device, site, keyword and organic result order. |
| DataForSEO | Set `DATAFORSEO_LOGIN`, `DATAFORSEO_PASSWORD`, `DATAFORSEO_ENABLED=true`, `DATAFORSEO_DAILY_TASK_LIMIT` and `DATAFORSEO_31_DAY_TASK_LIMIT` for the installation. The UTC-day and rolling 31-day limits count all reservations, including unconfirmed submissions. The rolling limit defaults to 31 times the daily limit. Zero for either holds new submissions. To restrict spending to approved keyword/device series, set `DATAFORSEO_ALLOWED_SERIES_IDS` to their comma-separated IDs. An empty or invalid configured list blocks all new submissions. Create a managed site using the provider's matching location. Each device check can incur a charge. Submissions are disabled by default. |
| Google Search Console | Enable the Search Console API in a Google Cloud project and create a Web OAuth client. For the default local address register `http://localhost:3038/search_console/callback`. Set `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`. Each workspace owner then connects their own verified matching property. The read-only report shows final Web performance with scoped dates and separate property totals. Google's average position and locally sampled daily positions use different methods. |
| Local Falcon | A workspace owner can connect a private Local Falcon account using the hosted OAuth flow, with a saved scan link or Google Place ID. Searchdesk verifies that the listing website matches the site, then checks daily for completed Google Maps scans, single-location campaign schedules and linked Business Profile interaction totals. The latest linked Business Profile totals replace the previous cache and expire after 29 days or on disconnect. The saved-link option also works on its own. |
| Google Analytics 4 | Enable the Google Analytics Admin API and Google Analytics Data API in the same operator Google Cloud project. Register `http://localhost:3038/analytics/callback` on the Web OAuth client. In **Integrations → Google Analytics 4**, the workspace owner grants read-only Analytics access and enters the numeric GA4 property ID. Searchdesk verifies a matching web stream and imports two 28-day Google organic periods for the selected host. Key events are unverified. |
| Website and Google Business Profile | Open the site's homepage or the provider portal. Each entry in the integration catalogue shows its implementation status. |
| AI wording | The application ships its own versioned recipes. For optional model calls the operator configures `ANTHROPIC_API_KEY` and `SEO_AI_MODEL` on the server. A workspace owner opts in under **Actions → Business wording preferences** and supplies approved public service descriptions. Ranking observations stay in Rails. Built-in reviews work out of the box. |

### Connect your OpenAI API project

Open **Assistant** to see which saved findings deserve attention and the evidence behind them. Searchdesk chooses relevant reviews for the selected site. When Google sharing is enabled, the weekly clicks review compares two seven-day periods and shows how many tracked searches had a reported click count on all 14 days. Opening the page reads saved data locally. Selecting a suggested AI question uses the workspace's configured OpenAI allowance. Enabled daily briefs use the same built-in reporting methods in the background. [Bundled skills and attribution](docs/skills.md)

Open **Assistant → Assistant settings** while signed in as the workspace owner. Enter a dedicated OpenAI project key with Responses write access, give the project a label, set your monthly USD allowance, then select **Test connection**. The test sends one synthetic request. OpenAI bills the selected API project. The allowance starts at $0 and covers the workspace's tests, questions and scheduled briefs in each UTC calendar month. Only installations operated by the API account owner accept credentials. The loopback Docker deployment enables this option. On an owner-operated private deployment, set `SEARCHDESK_OWNER_CONTROLLED_AI=true` on both the web service and worker.

For each site, enable the assistant and choose whether to generate a daily brief or delegate questions to managers. **Preview eligible facts** shows the daily evidence locally. Google reporting, Local Falcon and imported Semrush metrics have separate sharing controls. Use public business information in the project brief and questions. Approved sources stay linked in answers. A site member can read its published daily briefs. Each author can review their own questions and follow-ups.

The worker checks every 15 minutes. After 09:00 in the site's time zone it can generate today's brief when local ranking collection has settled. From noon it can proceed with the available evidence. Keep Docker and the Mac running for unattended collection. After downtime it can pick up the current day. Find the dated results under **Assistant → Daily briefs**. History removal keeps a minimal billing receipt. An interrupted provider call retains its estimated reservation so retries cannot bill twice.

Local web and worker services both read `.env`. Run `bin/start` after changing settings. Keep `.env` and a database backup together in secure storage. The application uses the persistent secret to protect sessions and derive encryption keys for Google tokens and workspace OpenAI credentials. Replacing the secret without a key migration invalidates access to existing encrypted data.

Verification and password recovery mail go to the private container volume at `/app/tmp/mail` locally. An operator can inspect it with `docker compose exec web ls /app/tmp/mail`. Set `SMTP_HOST`, `SMTP_PORT`, optional `SMTP_USER` and `SMTP_PASSWORD`, plus `MAIL_FROM` for actual delivery. Supply SMTP to both application processes when hosting.

## Deploy the same application

For a public HTTPS deployment with a continuously running worker, see the [hosting guide](docs/hosting.md). It covers Northflank Sandbox and a Docker VM on Oracle Cloud Always Free.

[![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy)

Place **this directory** at the root of its own GitHub or GitLab repository. From the hosted README, the button lets Render infer the repository. Alternatively select the repository in Render's **New Blueprint** screen. Review the proposed paid web service, worker and managed database before applying. The Blueprint configures private database access, runs migrations, generates a persistent secret and binds the worker to the web service. Configure optional provider and mail settings on both services, and register the public HTTPS Google callback before connecting a property. This repository contains the deployment definition. The local start does not provision cloud infrastructure. [Render deployment button](https://render.com/docs/deploy-to-render) · [Render Blueprint specification](https://render.com/docs/blueprint-spec)

## Development

Run `bin/verify` for test database preparation, the autoload check and the Rails suite. Inspect worker health in **Schedules**. For pinned versions and the action-review recipes, see [dependency verification](docs/dependencies.md) and [server-side skills](docs/skills.md).
