# Working on Searchdesk

Searchdesk is a Rails application for small-business owners. The owner chooses a site, adds keywords and connects services. Rails collects results and prepares evidence-linked actions in the background. SkinHampshire is a customer of the application. Keep new features usable by other sites and workspaces.

## Start a new task

1. Open the folder containing this file. On the owner's Mac it is `$HOME/Documents/ChatGPT/Searchdesk`. Run `git rev-parse --show-toplevel` and `git status --short --branch`. Check whether this task depends on any uncommitted work.
2. Create a fresh `codex/<task-slug>` branch for every new task before editing files. Start from the appropriate committed base, usually `origin/main`. If another task is using the checkout, create your branch in a separate Git worktree to give each task its own working files and index. Bring over only the uncommitted changes your task needs.
3. Find the feature, its code and its acceptance tests in the [development handoff](docs/HANDOFF.md). Follow the requested task. The handoff also contains candidate future work.
4. For the local installation, sign in with the existing Searchdesk account. **Integrations** shows the selected site's connections and data coverage. **Schedules** shows frequency, last result, next eligibility and worker health. These screens are the source for today's settings. [Dashboard](http://localhost:3038/dashboard) · [Integrations](http://localhost:3038/integrations) · [Schedules](http://localhost:3038/schedules)

## Run and verify

Run commands from this repository with Docker Desktop running. The application and its dependencies run in containers.

| Intent | Command | What to expect |
| --- | --- | --- |
| Inspect the installation | `docker compose ps -a` | `web` and `db` healthy, `jobs` running. The one-off `prepare` container normally exits with code 0. |
| Check web readiness | `curl -fsS -o /dev/null -w '%{http_code}\n' http://localhost:3038/up` | HTTP 200. Check worker health separately in **Schedules**. |
| Start the application or apply local source changes | `bin/start` | Builds the image, prepares the database and starts web and jobs. On a fresh installation it first generates the local environment file. |
| Test a change | `bin/verify` | Builds the working tree, prepares the separate `seo_workspace_test` database, checks Rails autoloading and runs the suite with test mail and job adapters. Live web and jobs keep using their existing image. |
| Apply an already verified build locally | `docker compose up --no-build --detach --wait` | Web and jobs use the built image. The prepare service applies pending migrations. Reload the browser before exercising the changed flow. |

Compose runs Rails in production mode against `seo_workspace` for normal use. App source is copied into the image at build time. A restart alone keeps the old source. Use `bin/verify` for tests. For schema changes, keep the migration and its matching `db/schema.rb` in the working tree. The test container's generated files disappear when it exits.

The Compose project name is explicitly `seo-workspace`. This connects the independent checkout to the existing `seo-workspace_pg19_data` and `seo-workspace_mail` volumes. Changing the Compose project name creates a separate storage namespace.

The Dockerfile, `.ruby-version` and checksummed `Gemfile.lock` pin the toolchain. For dependency work, check current stable versions and Rails compatibility with the [dependency guide](docs/dependencies.md).

For a UI change, start at the preceding screen and follow the actual links. Exercise the changed interaction at desktop and phone widths. For a device filter, confirm that the results and URL change, the control stays in view, and Back restores the previous selection. For a street map, reach Overview from Rankings and open a saved scan. This path has caught problems that a direct page load and passing Rails tests missed.

## Working boundaries

- Use the authenticated `current_site` and workspace membership for reads and writes. Keep unrelated tenants, locations, devices and data sources separate. Test changes to access or scope with a second site or workspace.
- Use fictional records and provider fixtures for development. DataForSEO submissions and OpenAI requests can incur charges. Preserve the owner's configured budgets, allowlists and site consent. Viewing a saved report or running the local tests is sufficient for most feature work.
- The installation's `.env`, persistent PostgreSQL volume and local recovery mail contain private data. Keep credentials, OAuth tokens, mail links, database dumps and unrestricted logs out of source control, prompts and fixtures. Preserve the existing `SECRET_KEY_BASE`, which protects access to encrypted credentials, and the Compose volumes when rebuilding.
- Searchdesk owns its Rails source and [original product specification](docs/design/Small-business-SEO-product-specification.pdf). Client SEO records, website work and private migration materials belong to the separate SkinHampshire project. The SaaS runs from this repository and its configured services.

## Finishing a task

Report the changed owner-facing behavior, the tests and browser flows actually exercised and any outstanding dependency. Say whether the fix is running at localhost or only present in source. Update the relevant handoff section when routes, setup, schedules or acceptance criteria change. Past verification results and their dates are recorded in the [acceptance log](docs/verification.md).
