# Development handoff

Searchdesk runs one Rails application image for the web service and background jobs. A business owner chooses a site, keywords and data sources. The application collects authorised data, evaluates evidence and prepares reviews. The technical lead accepts a work package after reproducing its owner-facing workflow and its failure paths.

## Implemented in the local build

| Area | Working entry point | Acceptance contract |
| --- | --- | --- |
| Accounts and tenancy | Sign in, sign up, account recovery, Workspace menu | Account-specific login sessions, owner/manager/viewer permissions, site switching, verified email for membership grants, stale-form rejection and per-user recovery. |
| Rankings | Rankings → keyword | First comparable observation per series, today's value, movement, actual URL, source, date and selected device. Pausing one device preserves its baseline. Manual files are validated against the selected series. |
| Automatic collection | Site setup → managed source | Resolve the place with the provider, reserve the daily task, submit once and poll for a matching result. Reconcile by correlation key after a lost acknowledgement. Global submission limit and per-site mode control spend. |
| Search Console | Integrations → Google Search Console | Server-side OAuth with state and PKCE. Owner selects a matching verified property. Encrypt tokens. Show date-scoped final totals, tracked-query detail and last successful sync. Rankings can display exact-query, country-filtered, all-device average position for each Pacific reporting day. Disconnect clears that site's credentials and reports. |
| Maps and Business Profile | Integrations → Local Falcon | Owner connects the provider via OAuth and PKCE. Verify the Google listing and website. The worker reads completed scans, campaign schedules and available Business Profile interactions daily. Show the scan date, grid and source. Managers can also save a shared report. |
| Google Analytics | Integrations → Google Analytics 4 | An independent read-only grant verifies property, web stream and hostname before collecting current and previous 28-day Google organic traffic. Key-event counts require separate validation before they can be reported as enquiries. |
| Project migration | Source evidence and project tasks | Idempotent, site-scoped imports retain dates, metrics, source records and stable task IDs. Managers can track a working status and notes while preserving the imported register. |
| Actions and AI | Actions → evidence / preview / business wording | Prepare a versioned review for a preferred-page mismatch or a sustained decline. Show the triggering observations. The optional server model selects a line from approved public descriptions. Revocation and limits are checked at dispatch. |
| Deployment | Start.command, bin/start, render.yaml | Loopback Rails service, privately networked PostgreSQL, migrations, durable worker and generated local credentials. The standalone project can be hosted as a Render Blueprint. |

Manual imports and the fictional demo are usable immediately. Scheduled organic collection, Search Console, model calls and outbound email each require their own operator setup. Manual source choice never produces synthetic observations. Real Google, DataForSEO and model credentials must be supplied through deployment configuration and a tenant's applicable consent.

### Daily Google position source

The collector requests the latest 28 final reporting days for each group of up to five watchlist terms. Results use Web search, property aggregation, country, date and query. The live selector requests each watchlist phrase as an exact lowercase query, preserving the matching scope of the historical query reports. Each site's two-letter country maps to Google's three-letter filter. Owner settings can set the country on a manual site. Site, property, country, query and reporting method identify a comparable series. The first day with impressions and a valid position supplies the baseline. A day omitted from a final query response has no position. No local rank is inferred from these national averages. [Search Analytics API](https://developers.google.com/webmaster-tools/v1/searchanalytics/query) · [Search Console position measurement](https://support.google.com/webmasters/answer/7042828) · [UN country codes](https://unstats.un.org/unsd/methodology/m49/overview/)

Historic imports use provider `gsc` and metrics marker `gsc_web_exact_query_property_all_devices_v1`. Store `country`, `property`, `search_type: web`, `device_scope: all`, dates and `daily` rows with date, clicks, impressions and average_position. Only complete, equivalently filtered UI exports should use `source_basis: complete_ui_report`. Live responses use `final_api` and keep the dates actually queried. A disconnect deletes live records for that integration and retains independently imported evidence.

## Development tickets

Each ticket can be handed to an engineer or a development agent with this directory as its working tree. Complete the first two tickets before enabling real provider collection at a hosted installation.

| ID | Owner and dependency | Deliverable and acceptance |
| --- | --- | --- |
| INT-01 | Connector engineer, after an entitled operator supplies a test account and explicit task allowance | Qualify one managed organic series on a real town and keyword. Match vendor task receipt, device, timestamp, actual ranking page and billed amount. Repeat retrieval and restart the worker. Show the same single charge and one daily observation. Capture redacted fixtures for any vendor variation. |
| INT-02 | Connector engineer, after a Google OAuth client and test property are available | Exercise real consent, selection, token refresh, final report and disconnect. Compare the dates, property totals and a tracked keyword/page with Google's own report. Revoke access and confirm that another tenant's grant is unaffected. |
| OPS-01 | Platform engineer, before a hosted customer installation | Use the Blueprint with an authorised hosting account, set up SMTP, exercise a real recovery message and prove a PostgreSQL and encryption-key restore in an isolated instance. Before opening public sign-ups with a platform-paid rank provider, enforce per-workspace entitlement and an allowance alongside the global daily cap. Define backup expiry and tenant deletion procedures. Check hosting access-log treatment of OAuth and password-reset URLs. |
| SEO-01 | Product engineer, can run independently of provider credentials | Extend page evidence with read-only checks of status, canonical, indexability, title and main heading for an enrolled site. Validate destinations on each retrieval. Store timestamp, exact page and which checks were possible. Build fixture tests and an owner-facing action using two comparable reads. |
| MAP-01 | Integrations engineer, building on the private report reader | Extend automatic comparison to grids with verified matching coordinates, spacing, radius and keyword. Imported pin-level comparisons can already be displayed with their provenance. Adding paid scan creation requires its own explicit allowance and receipt. |
| ACT-01 | Rails/WordPress engineer, after SEO-01 | Introduce one narrowly scoped link edit. Require a preview and exact owner approval, validate the original source before writing, verify both the saved source and the public page, and provide rollback. A failed or stale check must preserve the prior content. Develop against a disposable WordPress instance. |
| MET-01 | Analytics engineer, after defining the site's qualified enquiry events | Build on the live GA4 reader by verifying enquiry definitions, duplicates and test traffic against the owner's business records before displaying qualified counts. Keep unverified events and missing data clearly labelled. |
| AI-01 | Product/AI engineer, after the current wording contract is accepted | Extend approved-line selection to draft generation from owner-licensed site excerpts. Evaluate factual support, claims, citations, token budget, consent and per-sector review using synthetic inputs before enabling it. |

## Review procedure

1. Start with the browser path and acceptance criteria. Inspect the models, existing migration history and checksummed lockfile. Keep sample customers fictional.
2. Work in a separate branch for each ticket. New source or measurement settings need fixture coverage for missing data, duplicate work and provider failure. Permission changes need tests in two independent workspaces.
3. Build the Docker image, run `bin/verify` and exercise the changed feature through Rails. Test worker changes with an offline queue and a restart. Validate on PostgreSQL 18 for Render compatibility and 19 for local use when introducing database-specific SQL.
4. Deliver a reviewable commit with the test result, actual runtime versions and remaining acceptance dependencies. Capture real provider charges, publication and production edits only with the relevant authorisation.

Runtime and release notes are in [dependency verification](dependencies.md). Installed prompt recipes, privacy boundaries and receipt semantics are in [server-side skills](skills.md). Local acceptance evidence is in [verification](verification.md).
