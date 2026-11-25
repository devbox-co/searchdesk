# Shipped SEO skills

The Rails application chooses the analysis from the selected site's saved evidence. The owner can open the assistant to see findings and choose a follow-up. Searchdesk supplies the analytical prompts on the server.

## Guided review and daily brief

Searchdesk adapts selected instructions from two pinned MIT-licensed projects into its own analytical playbooks.

| Source | How Searchdesk applies it |
| --- | --- |
| Garrett Smith / GMB Gorilla, Local SEO Skills, local-reporting v1.2.0 | Report a change in terms a business owner can understand. Compare like measurements and name a useful next check. This applies to weekly search clicks, local ranking changes and geographically comparable Maps readings. [Pinned reporting skill](https://github.com/garrettjsmith/localseoskills/blob/c3b7a25b7d5cc370752d74cfea240ccf992a24db/skills/local-reporting/SKILL.md) · [License notice](Local-SEO-Skills-LICENSE.txt) |
| Daniel Agrici, Local SEO Brain | Tie statements to dated evidence and identify missing inputs. Describe the observed movement, leave its cause open when the records cannot establish it, and offer a follow-up the owner can choose. [Pinned operating instructions](https://github.com/AI-Marketing-Hub/local-seo-brain/blob/e0dd86f9010085dada9fb6ae128d5a3ef5ff0392/SKILL.md) · [Next-action reference](https://github.com/AI-Marketing-Hub/local-seo-brain/blob/e0dd86f9010085dada9fb6ae128d5a3ef5ff0392/scripts/guide_next_action.py) · [License notice](Local-SEO-Brain-LICENSE.txt) |

The [versioned playbooks](../config/assistant_playbooks/v1.yml) contain the owner questions, evidence sources and instructions for seven reviews. The [selector](../app/services/ai_assistant/playbooks.rb) matches them to the facts available for each request. The daily brief uses the applicable methods together in one budgeted model request. Each optional one-click investigation carries a fixed server-side question. Receipts record the playbook version and the keys used to prepare a model request. Rails calculates the measured values and supplies the links. The installation runs from these bundled instructions and its configured data sources.

## Keyword action review

The two action recipes declare their inputs, outputs and execution mode under `config/seo_skills/<id>/<version>/`. The fixed Ruby registry validates them and resolves their handlers at boot.

An accepted daily organic observation can trigger a page mismatch, or a decline of at least three positions from baseline on two consecutive observed days. The tracking rule supplies the observation IDs and site-specific evidence. The review recipe chooses an ordered set of checks for that rule. It stores the observed date, keyword, device, location, whitelisted supporting fields, recipe version and SHA-256 input digest with the steps. Repeating the same request returns the same receipt. Additional numerical or page evidence produces a new one. A review older than the previous local day tells the manager to refresh the observation.

These checks use established local SEO methods of matching one preferred page to a query and comparing rankings within a consistent device and market. Managers can inspect Google Search Console for supporting first-party page evidence. The app’s rules, steps and tests are original. [Google Search Console performance report](https://support.google.com/webmasters/answer/7576553) · [Google Search Central SEO starter guide](https://developers.google.com/search/docs/fundamentals/seo-starter-guide)

### Method provenance

Garrett Smith's keyword research and reporting guides informed the choice of a preferred page per query and consistent reporting scope. Local SEO Brain's claim ledger informed the dated evidence receipt. Claude SEO's on-page review informed the manager's title and heading checks. These links identify the design references at the reviewed revisions. The shipped Ruby rules, templates and wording-selection prompt were authored for Searchdesk. [Keyword research](https://github.com/garrettjsmith/localseoskills/blob/c3b7a25b7d5cc370752d74cfea240ccf992a24db/skills/local-keyword-research/SKILL.md) · [Local reporting](https://github.com/garrettjsmith/localseoskills/blob/c3b7a25b7d5cc370752d74cfea240ccf992a24db/skills/local-reporting/SKILL.md) · [Claim ledger](https://github.com/AI-Marketing-Hub/local-seo-brain/blob/e0dd86f9010085dada9fb6ae128d5a3ef5ff0392/references/claim-ledger.json) · [On-page review](https://github.com/AgriciDaniel/claude-seo/blob/468ed5b0d9e3249394783710e54abb02837e326b/skills/seo-page/SKILL.md)

## Public wording selection

A workspace owner can approve one to six public service descriptions for a single site. A fresh consent revision may transmit those lines to Anthropic with a fixed selection instruction and a model configured by the operator. The model can only return the one-based index of an existing line. The request contains no ranking history, page URL, internal identifier or user account field. The owner must check that the phrases contain public copy, including names or details that text validation cannot recognize.

The default installation uses local review steps. The optional selector requires an API key, a model and recorded owner consent. The job reserves one attempt before dispatch and serializes dispatch against revocation. A pending revision expires after 24 hours. Three attempts per site per UTC day is a request cap. Timeouts and interrupted requests consume their reservation. A lost response falls back to local steps. Disabling wording clears the descriptions and prior choice and preserves the minimal attempt ledger. A provider request that already started can complete before revocation is acknowledged. [Anthropic Messages API](https://platform.claude.com/docs/en/api/messages/create)
