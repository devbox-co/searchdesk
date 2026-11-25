# Local acceptance history

## 25 November 2026 · Existing Searchdesk installation

| Check | Observed result |
| --- | --- |
| Web and worker | Local `/up` returned HTTP 200. Compose showed healthy web and database containers, a running jobs container and a successful one-off prepare. The application confirmed recent Solid Queue worker, scheduler and dispatcher heartbeats. Ruby 4.0.10, Rails 8.1.4.1, latest applied migration `20261125012000`. |
| Rails suite | `bin/verify` passed Rails eager loading and 161 tests with 1,828 assertions on the separate test database. Zero failures, errors or skips. |
| Maps | All four saved SkinHampshire scans from 17, 19, 23 and 24 November had a validated 1000 × 1000 street map in local storage. Navigating from Rankings to Overview loaded the 24 November image. Street map and Pin grid both worked. |
| Device switching | At 1280- and 390-pixel browser widths, selecting Mobile or Desktop updated the overview chart and rankings without moving the controls. Keyword history used the selected device. Browser Back and Forward restored the overview selection and its scroll position. |
| OpenAI assistant setup | Rails eager loading and 162 tests with 1,846 assertions passed after the credit error and evidence selection changes. The changes were applied at localhost and `/up` returned HTTP 200. The owner settings preview showed citations from Google Search Console, GA4, Local Falcon Maps, Business Profile and imported Semrush rankings. The synthetic connection test reached OpenAI, which returned `credit_balance_exhausted`. Schedules showed the worker online and daily briefs waiting for API credits. |
| Latest daily SEO brief on Overview | After the credit grant and successful connection test, SkinHampshire’s first scheduled brief published at 11:45 GMT with three findings. On localhost, Rankings → Overview showed the brief card and its link opened the full report at desktop and 390-pixel widths. Rails eager loading and 163 tests with 1,872 assertions passed, including viewer access, evidence withdrawal and site switching. |
| Daily SEO brief design | The AI attribution and finding cards were verified on the published SkinHampshire report in Chrome at 1512 and 390 pixels. The dashboard CTA opened the full report by keyboard and the first citation opened Rankings. Rails eager loading and 163 tests with 1,881 assertions passed, including the separate AI and local-evidence labels. |

For a later task, check the running installation's [integrations](http://localhost:3038/integrations) and [schedules](http://localhost:3038/schedules) for current connection, worker and collection status.

## 25 November 2026 · Hosted Compose

`bin/verify` passed Rails eager loading and 192 tests with 2,174 assertions and zero failures, errors or skips. An isolated Compose stack prepared a fresh PostgreSQL database, returned HTTP 200 from `/up` and rendered sign-in through Caddy over locally trusted HTTPS. HTTP redirected to HTTPS. Solid Queue registered its worker and scheduler. The public DNS, certificate and SMTP checks require a hosted instance.

## 24 November 2026 · Initial clean installation

The production-mode Rails service ran on localhost:3038 with an empty customer database. Sign-in and /up returned HTTP 200. PostgreSQL, Puma and Solid Queue ran in separate web, database and job containers. The database stayed on the private Compose network. Docker bound the web port to loopback.

| Check | Observed result |
| --- | --- |
| Installed versions | Ruby 4.0.10, Rails 8.1.4.1, RubyGems and Bundler 4.1.0, Puma 8.1.2, Solid Queue 1.7.2 and PostgreSQL 19.0. The upstream check matched all eight declared gems plus Ruby, Bundler, RubyGems and PostgreSQL. |
| Rails acceptance | 50 tests and 434 assertions passed on PostgreSQL 19.0. Zero failures, errors or skips. Rails eager loading passed. The suite covers login and recovery, roles, cross-site isolation, location matching, daily rank and baseline semantics, provider recovery, Google OAuth and report scope, consent and model fallback. |
| First start and upgrade | Prepared empty databases from migrations and from the checked-in schema. Verified schema version 20261124005001 with no pending migrations and 13 queue tables. Running the local launcher again preserved configuration and data volumes. |
| Browser | Real Chrome on an isolated production-mode server at 390, 1120 and 1280 pixels. Completed registration, logout/login, site switching, demo onboarding, both devices, seven observation dates, action evidence and preview, saved Local Falcon report isolation and manual JSON entry through the import form. The manual observation recorded rank 2 and the expected landing page. The final run recorded zero JavaScript errors, HTTP error responses or external requests. |
| Demo accuracy | Five synthetic mobile series showed gains of 6 and 3, a fall of 6, an unchanged position and entry into the top 30. Baseline, current rank and delta were visible at 390 pixels. [Desktop capture](rankings-desktop.png) · [Mobile capture](rankings-mobile.png) |
| Worker recovery | On an isolated database, stopped the worker, kept the web endpoint available, queued a real ranking sweep and verified its persisted ready record. Restarted the worker and verified the same job finished successfully. Worker, dispatcher, scheduler and supervisor registered. The QA database recorded zero paid provider attempts. |
| Dependency advisory review | With bundler-audit 0.9.3 and the RubySec advisory database dated 22 November, no listed vulnerable versions matched the shipping lockfile. Separate Ruby, RubyGems and Bundler version checks also had zero matches. This covered package versions. [RubySec database revision](https://github.com/rubysec/ruby-advisory-db/tree/c87703e7f2c64f8745ce032711308a17d10cda55) |
| Hosting compatibility | The Render Blueprint passed the provider's published JSON schema. PostgreSQL 18.7, the current patch of Render's supported major, passed the migration, HTTP, worker and application checks in Docker. [Verification details](dependencies.md) |
| Isolation | The local application runs under container UID 10001. Private local credentials are ignored by Git and excluded from the image. Browser, connector and worker QA used disposable fictional data. The installation database was verified with zero business sites and zero user accounts at handoff. |

Provider contract tests exercise provider response shapes with synthetic fixtures. Live Search Console consent, paid organic collection, optional model selection and external mail delivery remain credentials-dependent acceptance tasks. The hosting Blueprint has been validated locally. The handoff lists the remaining provider and hosted deployment checks. [Development tickets](HANDOFF.md)
