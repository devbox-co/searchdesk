# SEO tasks and approvals

Open **SEO workflows** in the workspace navigation for a site-specific setup guide. It lists inputs, schedule status, outputs, and the latest result for each task. For workflows that accept imports, the owner’s link opens the relevant evidence form with the type and CSV headers shown. Members can read the guide and site-scoped reports. Open **Run or schedule tasks** to manage tasks. Workspace owners can run any of the 15 templates, enable recurring runs, import evidence, and review drafts. Other site members can read saved results. A report is scoped to the site, hostname and reporting period. A template that lacks the required evidence records that state and can fill in the same result once dated evidence arrives.

Recurring templates start disabled. The worker checks every 15 minutes from 08:00 in the site's time zone. Daily reports use the current date. Weekly, monthly and quarterly reports use the last complete period. Enabling a schedule partway through a period schedules the next boundary. **Run now** can review the last complete period immediately. Prospect audits run on demand. Live audits have their own saved reports so several prospects can be assessed on the same day.

**Preview current period** in Workflow setup shows saved evidence from the open week, month or quarter for M1, M4, M5, E3, E4, R1, R2, R4 and P2. The preview includes dates and links to the underlying evidence. It does not save a report, contact providers, trigger notifications or alter approvals. Run the normal task for the closed-period report. R1, R2 and R4 include captured M2 review summaries for weeks within their date range.

| Tier | Searchdesk behaviour |
| --- | --- |
| Autonomous | Generates a saved evidence report and records a completion or attention notification. |
| Queue | Holds the result or draft for a workspace owner. Searchdesk reminds the owner after 48 hours and expires an undecided draft after 72 hours. Owners can explicitly publish an approved post or reply to a verified Google Business Profile, or copy an approved draft for manual publication. |
| Notify | Holds the report for approval. The owner can record manual delivery or, on an enabled installation, preview a specific email recipient and explicitly confirm delivery. Searchdesk records the outcome and notifies the owner. |

Notifications appear under **SEO tasks**. A verified workspace owner can also opt in to email alerts for the selected site. Those messages contain a status and a link to sign in. The recipient's current permission and preference are checked again before sending. SMTP is required for real mail delivery. With Searchdesk's local file mail transport, owner alerts are saved to the local mail directory.

Client report email is disabled by default. An operator with an appropriate SMTP configuration can set `SEO_WORKFLOW_CLIENT_EMAIL_ENABLED=true`. The feature requires a verified workspace owner, an approved report, and a separate confirmation of the exact recipient. Messages with an uncertain delivery result are held for inspection and are excluded from automatic retries. Manual delivery remains available when client email is off.

### Slack alerts

Under **SEO tasks → Notifications → Slack alerts**, a workspace owner can connect a Slack incoming webhook scoped to an authorised channel. Searchdesk encrypts the webhook and sends only the status and an authenticated task link. Review requests, reminders, expiry, completion, attention and publication use the same events shown in the app. Disconnecting or replacing the webhook cancels pending messages bound to the previous channel. An unconfirmed delivery is held rather than replayed. [Slack incoming webhooks](https://api.slack.com/messaging/webhooks)

### Google Business Profile

Use an approved Google Cloud project for the operator's own authorised Business Profile use. Set `GOOGLE_BUSINESS_CLIENT_ID`, `GOOGLE_BUSINESS_CLIENT_SECRET` and `SEARCHDESK_GBP_WORKSPACE_ID` for a single operator-controlled workspace. Keep this feature disabled on a shared public demo. Register `/business_profile/callback` on the configured HTTPS application origin and enable the Business Information and Google My Business APIs. [Google API prerequisites](https://developers.google.com/my-business/content/prereqs) · [Business Profile API policies](https://developers.google.com/my-business/content/policies)

From **SEO tasks → Manage Google Business Profile connection**, authorise Google and enter the Google account and location IDs. Searchdesk verifies that the location belongs to the account and that its website matches the selected site. **Read live profile and reviews** reads the current profile and up to 50 recent review references, ratings and reply states. This view omits reviewer names and text and sends no API responses to the evidence archive.

An owner can approve an E1 or E2 draft in the app. Then check the exact location, text and review reference where applicable and click **Publish this post to Google** or **Publish this reply to Google**. This is a separate confirmation for each draft row. Searchdesk rechecks the binding before calling Google. For replies the current rating must match, and Searchdesk stops if Google already has a reply. A made-but-unconfirmed request is held for manual reconciliation. Provider receipt identifiers expire after 29 days. Disconnect in Searchdesk to remove the local grant, and revoke the grant in the connected Google account if no longer needed. [Google post creation](https://developers.google.com/my-business/reference/rest/v4/accounts.locations.localPosts/create) · [Google review reply update](https://developers.google.com/my-business/reference/rest/v4/accounts.locations.reviews/updateReply)

### DataForSEO Google review collection for M2

Bind one approved site with `DATAFORSEO_M2_SITE_ID`, `DATAFORSEO_M2_SITE_HOST`, `DATAFORSEO_M2_PLACE_ID` and `DATAFORSEO_M2_LOCATION_CODE`. **M2 → Run now with provider** submits up to 100 newest reviews once per reporting week and uses the account’s existing task limits. Workflow setup links to the pending report. The worker checks submitted results every 15 minutes and closes an unconfirmed request after 24 hours. Recurring submissions require both `DATAFORSEO_M2_SCHEDULED=true` and an enabled M2 schedule.

The saved evidence contains weekly counts, rating aggregates and observed reply coverage. Searchdesk discards review text, reply text, reviewer details and review IDs. A reply status is observed at collection. A four-week comparison requires sufficiently complete coverage of the report week and all four comparison weeks. [DataForSEO Google Reviews task submission](https://docs.dataforseo.com/v3/business_data/google/reviews/task_post/) · [Result contract](https://docs.dataforseo.com/v3/business_data/google/reviews/task_get/)

### DataForSEO Business Profile collection for M3

Use the existing DataForSEO login and password. Bind M3 to one approved site with `DATAFORSEO_M3_SITE_ID` and `DATAFORSEO_M3_SITE_HOST`, and supply its exact Google Place ID and the provider location code in `DATAFORSEO_M3_PLACE_ID` and `DATAFORSEO_M3_LOCATION_CODE`. This binding selects DataForSEO for M3 on that site. Under **SEO workflows → M3**, select **Run now with provider** for the baseline. Recurring collection requires `DATAFORSEO_M3_SCHEDULED=true` and the workspace owner to enable the M3 schedule.

DataForSEO submissions share the existing UTC daily and rolling 31-day task limits with rank tracking. Searchdesk reserves at most one attempt per site and reporting day, then requires an exact Place ID match. Compare subsequent readings from the same provider and market. Unavailable fields are excluded, and source evidence shows which fields were checked. [Business Info API](https://docs.dataforseo.com/v3/business_data/google/my_business_info/live/) · [DataForSEO pricing](https://dataforseo.com/pricing/business-data/business-data-api)

### Local SEO Data collection for M2, M3, M4 and E3

Configure the server's private environment for one approved site with `LOCALSEODATA_API_KEY`, `LOCALSEODATA_SITE_ID` and `LOCALSEODATA_SITE_HOST`. Set `LOCALSEODATA_ALLOWED_TASKS` to the comma-separated task IDs authorised to spend provider credits. Supply the canonical public `LOCALSEODATA_BUSINESS_NAME`. M2 and M3 also require the exact Google `LOCALSEODATA_PLACE_ID` and the market in `LOCALSEODATA_LOCATION`. E3 uses the public `LOCALSEODATA_ADDRESS` and `LOCALSEODATA_PHONE`.

**Run now with provider** queues collection in the worker. For recurring collection, also set `LOCALSEODATA_SCHEDULED_TASKS` to the approved subset and enable each task's schedule. Existing enabled schedules become eligible when their task is added to this subset. The app reserves at most one attempt per period per task and site. It keeps an unconfirmed attempt available as a receipt and leaves authorised imports usable. A completed report that already exists for the period is retained. Use a vendor sandbox key with a fictional site to exercise the flow before enabling paid collection. [Local SEO Data authentication](https://localseodata.com/docs/authentication) · [Pricing](https://localseodata.com/pricing)

- **M2** requests up to 100 newest reviews for the exact Place ID. It compares the completed week to the four prior weeks when the returned dates cover all five. It shows unanswered one- and two-star reviews as observed at collection. Searchdesk saves derived counts and sampled ratings. The review bodies, replies and reviewer identities are discarded.
- **M3** requests the public Business Profile for that exact Place ID, five credits per daily attempt. The first matching capture establishes a baseline. Later captures compare monitored fields with the latest comparable reading within 30 days. Searchdesk keeps field coverage and keyed fingerprints. Omitted fields remain unavailable, while a returned empty field is flagged if it previously held a value. The report can flag changes for review and links to both readings. Test-key samples remain labelled and do not trigger change alerts. [Business Profile API from Local SEO Data](https://localseodata.com/docs/business-profile)
- **M4** requests a dedicated Local Services Ads sample for `LOCALSEODATA_LSA_KEYWORD` and `LOCALSEODATA_LOCATION`. Set the public listing name in `LOCALSEODATA_BUSINESS_NAME` and advertised phone in `LOCALSEODATA_LSA_PHONE`, including the country prefix if the ads display it. The provider does not document a stable listing ID for this endpoint. Searchdesk requires one row with an exact name and matching phone digits. Phone numbers are omitted from the saved evidence. A dedicated scan costs two credits, with one attempt per reporting week. [Local Services Ads API](https://localseodata.com/docs/local-services-ads)
- **E3** requests 15 fixed directory checks without industry or aggregator add-ons. It reports provider-confirmed missing entries, NAP conflicts and duplicates, and counts unavailable and unverified checks. Prior comparisons require matching canonical inputs and conclusive results. Searchdesk saves directory identifiers and flags without storing listing URLs or raw NAP. [Google reviews contract](https://localseodata.com/docs/reviews) · [Citation audit contract](https://localseodata.com/docs/citation-audit)

### Run a live P1 prospect audit

From **Schedules → SEO tasks → Live prospect audits**, choose **New prospect audit**. Enter the prospect’s public hostname, business name, market and target search term. The worker checks up to five public pages behind the hostname’s robots policy and saves coverage, prioritised findings and next checks. The report belongs to the selected site and is available to workspace owners. Repeating the same target and inputs on the same local day reopens its report. Each site can start up to three distinct audits per local day. Imported prospect evidence is still available through **Run from imported evidence**.

For an optional Local SEO Data lookup, configure the same site-scoped key and allowlist used by M2 and E3, and add `P1` to `LOCALSEODATA_ALLOWED_TASKS`. The owner explicitly selects the 50-credit lookup. Searchdesk reserves at most one paid submission per local day for the configured site and polls the returned job on a fixed provider endpoint. An uncertain submission is left reserved. The provider matches by business name and market without an exact website or Place ID. Confirm the match before relying on its ranking, review and competitor observations. The target search term is recorded in the report. The provider selects the organic searches it runs. [Local SEO Data local-audit contract](https://localseodata.com/docs/local-audit)

## Evidence for the templates

Choose **Import or export evidence** and supply an authorised export for the current site. The source record stores the date, a SHA-256 fingerprint and derived metrics or the selected fields below. Review names and review text are discarded. The upload limit is 256 KiB. Structured signal exports accept up to 100 rows.

| Evidence type | Required CSV headers |
| --- | --- |
| Weekly review activity | `week_ending,new_reviews,average_rating,unanswered_low_rating,new_one_star`. Use a Sunday before the observation date, one complete week per row. Leave average rating blank if unavailable. Supply this week and the prior four consecutive weeks from the same location and source for a velocity comparison. Use a consistent low-rating threshold in the source export. |
| Citation NAP audit | `directory,listing_key,status,tier,name_match,address_match,phone_match`. Use the directory hostname and priority 1, 2 or 3. For listed rows supply a distinct local key and mark each public business name, address and phone match with `true`, `false` or `unknown`. Use one row with `status=missing` for a confirmed absence or `status=unverified` for an inconclusive check. Leave the key and match columns blank for those rows. The optional `listing_url` column accepts a public HTTPS page on the named directory. Searchdesk links to these pages from the evidence record and excludes unverified fields from issue-change counts. Listing keys and raw NAP are excluded from the saved audit. |
| Business Profile fields | `field,value`. Use `name`, `category`, `hours`, `website` or `services`. |
| Local Services Ads positions | `query,market,position` |
| AI search observations | `engine,prompt,market,mentioned,cited`. Use `google_ai_overviews`, `chatgpt`, `gemini` or `perplexity`, with `true` or `false` values. |
| Business Profile post brief | `service,approved_detail`. Supply public wording for the draft. |
| Landing page brief | `page,heading,paragraph,draft_storefront_schema,business_name,street_address,locality,region,postal_code,country_code,telephone`. Optional storefront fields are `business_type,latitude,longitude,opening_hours`. See the E4 setup below. |
| Unanswered review ratings | `review_ref,rating`. Use an authorised review reference without the reviewer's name and a rating from 1 to 5. Live publication requires an exact current Google review ID. |
| Prospect evidence | `target_host,check,observation`. Use a hostname and one of `website`, `business_profile`, `rankings`, `citations` or `reviews`. |
| Competitor market observations | `business,query,market,map_position,review_count,active_ad`. Use `true` or `false` for `active_ad`. |

Comparisons match exact scope fields in two different dated exports. Multi-location reporting uses saved monthly reports for locations explicitly opted in by their workspace owner. Choose **Download evidence for a private vault** for an owner-only bundle of up to 100 source summaries and 100 completed or approved reports. Use Local SEO Brain's `import-source` command to add the JSON to a private vault. The bundle omits email recipients, reviewer account identifiers and raw uploaded files.

### Prepare E4 landing-page drafts

Assign preferred URLs to the relevant tracked keywords and complete a site crawl in the reporting quarter. Upload a **Landing page brief** with one row per assigned public URL. Supply the exact public heading or locally specific paragraph for review. Export at most 20 rows in a single brief. The latest dated brief replaces the previous set for that site. E4 suggests the supplied heading for a page without an H1 and the supplied paragraph when fewer than 500 words were measured in the page's static main content. Treat that count as a review prompt.

To review schema for one physical storefront, set `draft_storefront_schema=true` on its public location page. Supply the public business name, street address, locality, country code and international telephone with its leading plus sign. Include the public region and postal code where applicable. Verify these values against the public Business Profile and the page before approval. Leave address and contact fields empty for a service-area or private-address business. Supply optional `business_type` such as `MedicalClinic`, `BeautySalon` or `Plumber`, both map coordinates with five to nine decimal places, and regular `opening_hours` such as `Mo-Fr 09:00-17:00 | Sa 10:00-14:00`. E4 compares fields when it can identify a single supported JSON-LD business entity for that page. It treats a multi-type entity as a match when it lists the expected subtype. It compares coordinates at five decimal places and normalises daily hours across different day groupings. Dated exceptions are excluded from the regular weekly comparison. An older crawl prompts for a fresh reading before it makes claims about the expanded fields. For pages with no detected static markup, it proposes a `LocalBusiness` JSON-LD block. Check the rendered page and any site-wide schema before applying it. [Google Local Business structured data](https://developers.google.com/search/docs/appearance/structured-data/local-business) · [Structured data policies](https://developers.google.com/search/docs/appearance/structured-data/sd-policies)

Open **E4 → Run now** to review the findings and exact draft, or **Refresh pending draft** after uploading a newer brief. Reload before approving if the draft changes. Approval records the reviewed version for manual application. A new crawl supplies the word count and markup observations for older crawl receipts.

## Local SEO Skills template coverage

All 15 templates run in Searchdesk. Searchdesk uses connected provider evidence, saved observations, and authorised imports. [Garrett Smith / GMB Gorilla’s task catalogue at the pinned revision](https://github.com/garrettjsmith/localseoskills/tree/c3b7a25b7d5cc370752d74cfea240ccf992a24db/tasks) · [Approval workflow](https://github.com/garrettjsmith/localseoskills/blob/c3b7a25b7d5cc370752d74cfea240ccf992a24db/specs/approval-workflow.md) · [MIT notice](Local-SEO-Skills-LICENSE.txt)

| Task | Searchdesk implementation |
| --- | --- |
| M1 Weekly rankings monitor | Organic coverage and movement grouped by device. Connected Local Falcon scans add share of voice and top-three pin gains or losses on matched Google Maps grids. Owners can request a one-off credit-backed grid, or import an existing verified scan. Campaign results can also be read through the integration. A structured Brain import creates a dated note for each saved grid. Older archived grids qualify when their saved pins match the verified Place ID and the original Local Falcon report. Recurring paid scans and configurable Maps-drop alerts remain open. |
| M2 Review velocity | Collects Google reviews through DataForSEO or Local SEO Data or compares authorised weekly imports. Flags a drop over 40% for comparable weeks, new one-star reviews or unanswered low ratings. Independently verified sentiment and deeper review feeds remain pending. |
| M3 Business Profile changes | Compares daily DataForSEO or Local SEO Data readings for a verified Place ID or uses dated field exports. The separately bound publishing connection can read the current profile on demand from Google. [Google’s Business Profile API storage policy](https://developers.google.com/my-business/content/policies#content_storage) limits how API content can be retained and used. |
| M4 Local Services Ads ranks | Compares dedicated weekly Local SEO Data samples for the same query, market and listing. Flags a drop of three or more positions, leaving the top three, or an identifiable new top-three competitor. Also shows DataForSEO panel coverage and compares exact Place ID matches across adjacent weeks. Authorised imports remain available. |
| M5 AI visibility | Compares imported mentions and citations. Counts links in saved Google AI Overview results and shows owner-triggered Google AI Overview, ChatGPT, Gemini and Perplexity citation samples. |
| E1 Business Profile post drafts | Builds drafts using approved service details. Each approved post can be explicitly published to a verified GBP location. |
| E2 Review response drafts | Drafts a response using a review reference and rating. Each approved reply can be explicitly published after Google confirms the review is still unanswered. |
| E3 Citation audit | Collects live checks from Local SEO Data or uses authorised imports. Reports NAP mismatches, duplicates, missing listings and incomplete coverage. Compares conclusively checked directories within each source. |
| E4 Local page content audit | Queues assigned-page findings, exact owner-supplied copy, and public storefront schema drafts. Compares name, address, phone, supported subtype, map coordinates and regular opening hours against the brief when a single matching JSON-LD entity is present. Compares public HTML signals on a selected site page and competitor page. Rendered page checks remain pending. |
| R1 Weekly performance report | Compares adjacent weeks for organic rankings, matched Maps grids, the verified listing in complete top-three samples, and review activity. Flags gaps and selects one next action. The structured Brain import carries those readings, source links and the next action into a dated weekly report. |
| R2 Monthly client report | Includes saved AI visibility and local pack comparisons across adjacent months. Queues approval, then offers confirmed SMTP delivery on enabled installations or a manual delivery receipt. |
| R3 Multi-location rollup | Reports monthly Maps visibility, review coverage, critical issues and brand-level patterns for opted-in locations. Flags locations missing a monthly report and retains the portfolio in the private vault export. |
| R4 Quarterly business review | Queues a 90-day review with dated ranking, Maps, review, competitor and AI evidence, plus measurable next-quarter priorities. |
| P1 Prospect audit | Saves a private, live public-page audit with a prioritised checklist. An optional Local SEO Data lookup adds ranking, profile, review and competitor observations by business name and market. Imports remain supported. Dedicated geogrid, citation and AI visibility prospect checks remain open. |
| P2 Competitor market monitor | Compares the latest Google local pack sample for the same tracking series in successive closed months. Shows entrances, departures, movement, displayed review or rating changes and matches to sponsored listings in those captures. Authorised competitor imports remain available. |

The Google SERP readers use already-budgeted organic captures. They do not request new tasks, enable asynchronous AI Overview loading or infer absence from an unavailable payload. Direct collection for additional AI engines, competitor review feeds, broader advertising activity and additional prospect checks remains pending. The upstream templates' richer analyses and provider-specific output contracts also remain pending. [DataForSEO Advanced Google SERP contract](https://docs.dataforseo.com/v3/serp/google/organic/task_get/advanced/)

### Request a Local Falcon grid in M1

Open **Workflow setup → M1 → Request a live Local Falcon scan**. Connect Local Falcon and verify this site's Google Business Profile first. Select a tracked term, a 3×3, 5×5 or 7×7 grid, and a radius in miles. Searchdesk centres the grid on the verified listing and shows the existing credits required for the selected size. One request per site per day can be queued. The worker checks the current owner, connection and keyword, then submits the scan once. It polls the same report key and never repeats a paid submission after an uncertain response.

Open **View saved grid** or **Preview current period** for the reading. A single grid is a baseline. Pin changes require a second grid for the same keyword and coordinates. Use **Import an existing Local Falcon grid** to recover a completed report from the same verified location by key.

The private Local SEO Brain JSON includes up to 20 dated, site-scoped grids with source references. **Download grid CSV for Local SEO Brain** on a saved scan produces a file for the pinned `import-geogrid` command. Pass the slug of an existing location note with `--location`. In CSV, reported ranks outside the top 20 use 21 for the importer and retain the original provider value. Unavailable ranks stay blank. [Local Falcon grid options](https://docs.localfalcon.com/guides/grid-configuration)

### Check DataForSEO Local Services Ads coverage

Open **Workflow setup → M4 → Recover Local Services Ads evidence**, then select a tracked search and device. Searchdesk checks the most recent available paid ranking receipt in each of the current and previous weeks. The existing search provider setting and a locally verified Business Profile Place ID are required. Future DataForSEO ranking captures also store this evidence. View the result in **Preview current period** or wait for the regular closed-week report.

The result records whether a local services panel was returned and whether an ad matched the exact verified Place ID. A positive result links back to the sampled listing position. Adjacent weeks are compared only when the same tracked search, market and device produced a verified position in both weeks. A sample without a panel or verified match does not establish account or campaign status. [DataForSEO Advanced Google SERP contract](https://docs.dataforseo.com/v3/serp/google/organic/task_get/advanced/)

### Compare dedicated LSA scans

From **Schedules → SEO tasks**, use **Run now with provider** for M4 or enable its paid schedule. The scan is dated when collected. M4 compares it with the previous reporting week only if both matched and used the same configured scope. Empty, unmatched and ambiguous samples are kept as evidence without assigning a rank. A dropped position describes the sampled results. Test-key samples are labelled and do not trigger dedicated-scan movement alerts. [Google Local Services Ads overview](https://support.google.com/localservices/answer/6224841)

### Compare local competitors

P2 uses the existing DataForSEO ranking schedule. An owner can select one search and device in **Workflow setup → P2 → Recover ranking evidence**. The worker can retrieve the most recent still-available paid result in each of the current and previous months and attach its local-pack evidence to the original dated ranking. It checks the saved provider reference, capture time and tracking scope. Recovery uses DataForSEO's read-only result endpoint, which makes those results available for 30 days. **Preview current period** shows the baseline and any comparable prior-month capture. New captures save up to three identifiable unpaid listings from the first-page local pack, with the displayed review counts and ratings when supplied. Searchdesk compares the most recent saved sample in each month for the same keyword, market and device. Entrances and departures require three distinct Google listing IDs in both months. Missing or partial samples remain visible without a movement claim. A matched sponsored row is evidence from that search sample. The report links to both captures when a comparison is available. [DataForSEO local pack response fields](https://docs.dataforseo.com/v3/serp/google/organic/task_get/advanced/)

### Compare competitor pages in E4

In **Workflow setup → E4**, a workspace owner can submit two public HTTPS pages for the same service, one on the selected site and one on a competitor site. The worker obeys robots.txt and keeps redirects within each page’s host. Each site can submit three distinct pairs per local day. Submitting the same pair reuses the saved comparison for that day.

Open the comparison in **Recent page comparisons** or **Preview current period**. It shows page title, meta description and H1 availability, approximate main-content word and subheading counts when a main landmark is available, and whether a single matching storefront JSON-LD entity was found. The record links to both sources and shows why a page was unavailable. Searchdesk keeps the signals and URLs without storing page copy. These checks use server-returned HTML.

### Read the R1 weekly performance report

Open **Workflow setup → R1** for the latest saved report and the current-week preview. R1 compares the most recent comparable reading in each week for the same keyword, device and market. The preview compares the same elapsed weekdays in both weeks and leaves review totals unavailable until the week has closed. Maps changes require matched pins. Top-three findings require a complete panel and a verified listing identity. Review changes require complete weeks from the same evidence feed.

The report marks partial coverage, states the most important finding and gives one evidence-linked action. Scheduled R1 runs from Monday at 08:00 in the site's time zone, after M1 and M2 have been checked. A later captured M2 receipt for that week can refresh the same report. Run again to include late manual evidence. Completed reports retain their structured measurements and next action in the private Local SEO Brain export. [Garrett Smith’s R1 template](https://github.com/garrettjsmith/localseoskills/blob/c3b7a25b7d5cc370752d74cfea240ccf992a24db/tasks/r1-weekly-report/TASK.md)

### Run the multi-location rollup for R3

Each workspace owner can include a location under **SEO tasks → Multi-location reporting**. Include at least two locations in the same workspace and generate R2 for each location. R3 uses a saved R2 for the exact closed month, including drafts available for internal review. It does not send those drafts. Set up one R3 schedule on the location where the portfolio should be saved. A scheduled R3 can run from 10 am on the first day of the month in that site's reporting time zone. Run R3 again to refresh a partial result as more reports become available.

The portfolio shows urgency, average rank position (ARP), Share of Local Voice (SoLV), measured review volume and average rating of new reviews, and critical findings. Maps changes require a matching keyword and grid in the prior month. Review volume counts complete Monday–Sunday weeks inside each month. A review trend compares per-week rates only with complete coverage from one comparable feed. Unavailable metrics and missing reports remain visible. Issues observed at three or more locations are flagged as brand-level patterns. Use **Open monthly report** to switch to the location and read its evidence.

The private Local SEO Brain JSON includes structured R3 coverage, location metrics, and the relative R2 report references. Opting a location out removes its rows from the displayed and newly exported portfolio. Import the JSON as a private source with the pinned bridge. [Garrett Smith’s R3 template](https://github.com/garrettjsmith/localseoskills/blob/c3b7a25b7d5cc370752d74cfea240ccf992a24db/tasks/r3-multi-location-rollup/TASK.md)

### Review AI visibility and competitors in R2 and R4

In **Workflow setup**, open the R2 or R4 **Preview current period** to see saved AI visibility and competitor evidence alongside the performance report. The report uses the same shareable summaries as M5 and P2. It shows captured AI response samples from the selected period. Imported trend comparisons require matching scopes in adjacent reporting periods. For local packs, R2 compares the latest sample in each adjacent month and R4 uses adjacent quarters. A comparison requires two complete samples of the same keyword, market and device. Otherwise the captured baseline and its coverage are shown.

The preview uses existing evidence and requests no new provider data. Closed-period drafts keep their existing approval and delivery steps. The owner-only Local SEO Brain download retains relative source and comparison links for supported records in completed or approved reports. Resolve these links against the Searchdesk installation that produced the export.

### Review the next quarter’s priorities in R4

Open **Workflow setup → R4 → Preview current period**. The performance section uses the 90 days ending on the displayed date. It compares the first and last measured organic positions for the same active keyword and device, shows matched Maps grids when available, and lists complete review weeks with gaps identified. Competitive snapshots use adjacent calendar quarters. AI citation comparisons require the same prompt fingerprint, engine, model and market. The review identifies wins and issues from the saved measurements, then ranks up to five actions with a source or setup link and a measure to check next quarter.

The first saved closed-quarter R4 is queued for owner review. The private Local SEO Brain JSON includes its structured 90-day review and priorities after approval. The preview uses saved evidence and incurs no provider calls. [Garrett Smith’s R4 template](https://github.com/garrettjsmith/localseoskills/blob/c3b7a25b7d5cc370752d74cfea240ccf992a24db/tasks/r4-quarterly-business-review/TASK.md)

### Collect an AI response sample

In **Workflow setup → M5**, a workspace owner can review the configured public prompt and country, then choose an engine to queue a billable sample. Set `DATAFORSEO_AI_SITE_ID` and `DATAFORSEO_AI_SITE_HOST` to the approved site, `DATAFORSEO_AI_WEB_PROMPT` and `DATAFORSEO_AI_WEB_COUNTRY` to the exact approved inputs, and `DATAFORSEO_AI_WEB_ENGINES` to the approved subset of `google_ai_overviews,chatgpt,gemini,perplexity`. The worker rechecks the inputs and current ownership just before sending the request. The latest samples are visible immediately under M5, and completed monthly reports include samples dated within the reporting month. ChatGPT, Gemini and Perplexity samples record usable citations from their API responses. [DataForSEO ChatGPT response contract](https://docs.dataforseo.com/v3/ai_optimization/chat_gpt/llm_responses/live/)

For Google AI Overviews, Searchdesk sends the exact question as a desktop Google search in the site's verified market. The verified market must belong to the configured country. It requests one results page with asynchronous overview loading enabled, which can add a supplier charge. The evidence distinguishes an absent overview, unavailable content, and an overview with usable citation URLs. Only links in the overview count toward citation coverage. The operator command below accepts `DATAFORSEO_AI_ENGINE=google_ai_overviews`. [DataForSEO Advanced Google SERP contract](https://docs.dataforseo.com/v3/serp/google/organic/live/advanced/)

Each sample shares the daily and rolling DataForSEO task limits with the ranking and Business Profile workflows. Searchdesk reserves at most one sample per engine and UTC day for the site. Review the provider’s pricing before approving a prompt. [DataForSEO AI pricing](https://dataforseo.com/pricing/ai-optimization/llm-responses)

Use a single explicitly approved site with `DATAFORSEO_AI_SITE_ID` and `DATAFORSEO_AI_SITE_HOST`. DataForSEO must already be enabled with credentials. Review provider pricing and obtain the current workspace owner’s approval for the prompt and spend. Send public search copy only. Set the country and engine, then send the prompt on stdin. Searchdesk prefixes it with the country as in the example.

```sh
printf '%s\n' 'Where can I find a boiler installer in Bath?' |
  docker compose exec -T -e DATAFORSEO_AI_APPROVED=true -e DATAFORSEO_AI_OWNER_ID=42 \
    -e DATAFORSEO_AI_COUNTRY=GB -e DATAFORSEO_AI_ENGINE=gemini web bin/rails seo:sample_ai_visibility
```

This submits one paid request per engine per UTC day at most, including attempts whose result could not be confirmed. The command checks current workspace ownership. It stores a prompt fingerprint, scope, citation counts and a provider reference. M5 shows samples within the closed monthly period and links to the saved source evidence. These provider API samples measure the supplied responses. An empty citation list leaves the site citation result unknown. [Gemini API](https://docs.dataforseo.com/v3/ai_optimization/gemini/llm_responses/live/) · [Perplexity API](https://docs.dataforseo.com/v3/ai_optimization/perplexity/llm_responses/live/)

## Local SEO Brain

Run `bin/seo-brain refresh-queue --as-of YYYY-MM-DD` with the pinned checkout configured to list items requiring review in due-date order. The queue includes pinned source links for overdue sources and claims and retains the upstream freshness check’s nonzero status when review is due.

Workspace owners can download an Obsidian vault for the selected site from **SEO workflows → Run or schedule tasks → Import or export evidence → Download Local SEO Brain vault**. Unzip the file, open the extracted folder as a vault in Obsidian, then go to **Reports Hub** for R1 or **Sources Hub** for M1. Each download is a fresh snapshot. Keep any locally edited vault in its own folder.

Rails builds the selected site's private evidence bundle and calls the shared importer. The web image contains the pinned upstream runtime and template. The server prepares the vault in a temporary directory, returns the ZIP as an attachment and removes the working files. Source links open Searchdesk and require access to the corresponding workspace. The download makes no provider requests. [Daniel Agrici’s Local SEO Brain at the pinned revision](https://github.com/AI-Marketing-Hub/local-seo-brain/tree/e0dd86f9010085dada9fb6ae128d5a3ef5ff0392) · [MIT notice](Local-SEO-Brain-LICENSE.txt)

| Capability | How to exercise it |
| --- | --- |
| Structured R1 and M1 handoff (complete) | Choose **Download Local SEO Brain vault** to generate dated R1 reports and M1 grids on the server. The CLI uses the same importer when updating an existing vault. |
| Private Obsidian vault and immutable raw evidence | `bin/seo-brain scaffold`, then `import-source`, `import-gbp`, `import-citations`, `import-reviews` or `import-geogrid`. |
| Pinned source and claim ledgers, freshness, contradictions and coverage | `bin/seo-brain evidence validate`, `evidence freshness`, `evidence check`, and `coverage check`. |
| Draft scorecard, roadmap, weekly report and next action | `bin/seo-brain synthesize`, `lint`, `report` and `next-action`. |
| Knowledge refresh and template demo | `bin/seo-brain refresh-knowledge` uses the operator's lawfully held historical seed when required. `demo` generates a standalone Obsidian demo from upstream fixtures. |
| Release verification and packaging | `bin/seo-brain audit`, `verification` and `package` expose the upstream interfaces. Packaging requires the upstream verification inputs, an Obsidian CLI and a Brainstein checkout. |

For operators importing into an existing vault, download **raw evidence (JSON)**. The CLI requires Git and Python 3.11 or newer. Set `SEARCHDESK_SEO_BRAIN_REPO` to an absolute checkout of the upstream repository containing the pinned revision. Keep vaults, raw exports and delivery receipts outside tracked source. Each command accepts the corresponding upstream arguments and supports `--help`.

```sh
export SEARCHDESK_SEO_BRAIN_REPO=/absolute/path/to/local-seo-brain
bin/seo-brain scaffold --client sample --owner "Fixture Owner" --out-dir /absolute/path/to/private-vaults --as-of 2026-10-15
bin/seo-brain import-searchdesk --vault /absolute/path/to/private-vaults/sample \
  --file /absolute/path/to/searchdesk-seo-evidence.json --site-host sample.example \
  --searchdesk-url http://localhost:3038 --as-of 2026-10-15
bin/seo-brain lint --vault /absolute/path/to/private-vaults/sample
```

Use the selected site's domain for `--site-host` and the app's origin for `--searchdesk-url`. Use a fresh download so the bundle contains the workspace-specific site identifier. If the latest closed-week R1 report predates structured measurements, run R1 again before downloading. Older unstructured rows stay in the raw export. The first import binds the vault to that Searchdesk site. Use a separate vault for another site or workspace, including one that uses the same domain. Add `--dry-run` to validate without writing.

Open **Reports Hub** for dated R1 notes and **Sources Hub** for M1 grids and raw export receipts. Reimporting an identical file reuses its receipt and note names. A newer export can refresh a weekly note for the same period. Original JSON bytes are preserved. Searchdesk links require the appropriate signed-in site. The exported report status is preserved as a fact and the generated note remains a draft. R2–R4 and other bundle sections are retained in the raw file. The upstream `synthesize` and `report` commands still produce the starter weekly report separately.

Use the actual import date and current ledgers outside the fixture example. The original historical course bundle is operator-supplied material. The normal installed vault includes the upstream generated notes and does not require the course bundle. Scheduled ledger maintenance and upstream release packaging remain operator workflows.

The pinned release checker repositories were inaccessible from the verification account. Their pinned revisions and compatibility patches are specified by the upstream [release checklist](https://github.com/AI-Marketing-Hub/local-seo-brain/blob/e0dd86f9010085dada9fb6ae128d5a3ef5ff0392/RELEASE_CHECKLIST.md). The pinned evidence snapshot passed its fixture-date coverage checks, but the freshness check for 26 November 2026 reports 215 actionable records. Current release verification remains pending.
