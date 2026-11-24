# Searchdesk

Searchdesk is a self-hostable Rails application for small businesses tracking their visibility in Google. The owner signs in, adds keywords and chooses sources. A separate server process collects authorised data and prepares actions after the browser closes.

## Start on a Mac

With Docker Desktop running, double-click **Start.command**. On Linux or in a Mac terminal, run `bin/start` from this directory. The first start downloads the official images, generates local secrets, migrates PostgreSQL and starts the web server and job worker. Open [Searchdesk locally](http://localhost:3038).

1. Choose **Create an account** from the sign-in screen.
2. To explore immediately, select **Demo** on the setup screen and create the site. Its sample business has five fictional keywords with seven days of observations on two devices.
3. For your own business, create a separate site from **Workspace → Set up a site**. Use manual mode for imported observations, or managed collection after configuring the provider. **Integrations** shows the available methods and the worker's health.
4. In **Rankings**, choose a device and open a keyword to see the observed dates, winning page and history. **Actions** links each recommendation to the evidence that triggered it.

The app listens on the local loopback interface. To change the port, set both `LOCAL_PORT` and `APP_HOST` in `.env` and restart. Use the same hostname when signing in and configuring OAuth. Docker keeps database and local mail volumes between launches. `docker compose stop` stops the app. `bin/start` starts it again. Scheduled jobs need Docker and the host to be awake. A missed collection remains identifiable on the dashboard.

## How tracking works

A keyword gets a separate series per source, location, device, language and measurement method. The first comparable observation fixes the baseline. The dashboard compares today's observed organic position with that baseline. An absent reading has no numeric delta. A verified top 30 without the site means **Outside 30**. Short result sets without enough evidence remain incomplete. Each row also records which page ranked. A preferred-page mismatch or two consecutive materially lower positions can open an evidence-linked action.

Rails and Solid Queue share one PostgreSQL database in this implementation. The web service, worker, scheduler and dispatcher use one application image. The scheduler checks due slots every five minutes and targets 08:00 in each site's reporting time zone. Newly enrolled keywords have a slot immediately. Submissions have a durable correlation key and quota reservation. Polling can resume after restart. Unconfirmed submissions are held for reconciliation. Closing the browser leaves these processes running.

## Connections

| Capability | How to use it |
| --- | --- |
| Manual organic ranks | On a manual site, open the keyword and choose **Import observation**. The form gives a scoped JSON example. The server validates the capture date, device, site, keyword and organic result order. |
| DataForSEO | The operator sets `DATAFORSEO_LOGIN`, `DATAFORSEO_PASSWORD`, `DATAFORSEO_ENABLED=true` and a `DATAFORSEO_DAILY_TASK_LIMIT` for the installation. Create a managed site using the provider's matching location. Each daily device check can incur a charge. The default configuration disables submissions. |
| Google Search Console | Enable the Search Console API in a Google Cloud project and create a Web OAuth client. For the default local address register `http://localhost:3038/search_console/callback`. Set `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`. Each workspace owner then connects their own verified matching property. The read-only report shows final Web performance with scoped dates and separate property totals. Google's average position and locally sampled daily positions use different methods. |
| Local Falcon | A workspace owner can connect a private Local Falcon account using the hosted OAuth flow, with a saved scan link or Google Place ID. Searchdesk verifies that the listing website matches the site, then checks daily for completed Google Maps scans, single-location campaign schedules and linked Business Profile interaction totals. The latest linked Business Profile totals replace the previous cache and expire after 29 days or on disconnect. The saved-link option also works on its own. |
| Google Analytics 4 | Enable the Google Analytics Admin API and Google Analytics Data API in the same operator Google Cloud project. Register `http://localhost:3038/analytics/callback` on the Web OAuth client. In **Integrations → Google Analytics 4**, the workspace owner grants read-only Analytics access and enters the numeric GA4 property ID. Searchdesk verifies a matching web stream and imports two 28-day Google organic periods for the selected host. Key events are unverified. |
| Website and Google Business Profile | Open the site's homepage or the provider portal. Other entries in the sixteen-service catalogue show their implementation status. |
| AI wording | The application ships its own versioned recipes. For optional model calls the operator configures `ANTHROPIC_API_KEY` and `SEO_AI_MODEL` on the server. A workspace owner opts in under **Actions → Business wording preferences** and supplies approved public service descriptions. Ranking observations stay in Rails. Built-in reviews work out of the box. |

Local web and worker services both read `.env`. Run `bin/start` after changing settings. Keep `.env` and a database backup together in secure storage. The application uses the persistent secret to protect sessions and derive encryption keys for Google tokens. Replacing the secret without a key migration invalidates access to existing encrypted data.

Verification and password recovery mail go to the private container volume at `/app/tmp/mail` locally. An operator can inspect it with `docker compose exec web ls /app/tmp/mail`. Set `SMTP_HOST`, `SMTP_PORT`, optional `SMTP_USER` and `SMTP_PASSWORD`, plus `MAIL_FROM` for actual delivery. Supply SMTP to both application processes when hosting.

## Deploy the same application

[![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy)

Place **this directory** at the root of its own GitHub or GitLab repository. From the hosted README, the button lets Render infer the repository. Alternatively select the repository in Render's **New Blueprint** screen. Review the proposed paid web service, worker and managed database before applying. The Blueprint configures private database access, runs migrations, generates a persistent secret and binds the worker to the web service. Configure optional provider and mail settings on both services, and register the public HTTPS Google callback before connecting a property. This repository contains the deployment definition. The local start does not provision cloud infrastructure. [Render deployment button](https://render.com/docs/deploy-to-render) · [Render Blueprint specification](https://render.com/docs/blueprint-spec)

## Development

Run `bin/verify` for the isolated database migrations, autoload check and Rails suite. The suite disables external credentials. Run `docker compose logs --tail 50 jobs` to inspect the worker. Read [the development handoff](docs/HANDOFF.md) for the next independently assignable tasks, [dependency verification](docs/dependencies.md) for pinned versions and [server-side skills](docs/skills.md) for the prompt and evidence contract.
