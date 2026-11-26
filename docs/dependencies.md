# Runtime and dependency versions

Checked against upstream stable releases on 24 November 2026. The application image uses Ruby 4.0.10 on Debian 13 and Bundler 4.1.0. The frozen lockfile includes package checksums and native Linux ARM64 and x86-64 builds. [Ruby releases](https://www.ruby-lang.org/en/downloads/) · [Bundler releases](https://rubygems.org/gems/bundler/versions)

| Direct dependency | Installed release |
| --- | --- |
| Rails | 8.1.4.1 |
| pg | 1.7.0 |
| Puma | 8.1.2 |
| bcrypt | 3.1.22 |
| Solid Queue | 1.7.2 |
| Propshaft | 1.3.2 |
| importmap-rails | 2.2.3 |
| turbo-rails | 2.0.23 |

The local Compose stack uses PostgreSQL 19.0 with a dedicated major-version volume mounted at `/var/lib/postgresql`. Future database major upgrades require a dump and verified restore or pg_upgrade. [PostgreSQL version policy](https://www.postgresql.org/support/versioning/) · [Official image volume layout](https://hub.docker.com/_/postgres)

The image installs RubyGems and Bundler together at 4.1.0. To check the full dependency tree, run `docker compose run --rm --no-deps -e BUNDLE_DEPLOYMENT=false -e BUNDLE_FROZEN=false web bundle outdated`. The review found one indirect dependency behind its upstream major. Rails Active Storage 8.1.4.1 requires Marcel 1.x, so the resolver installs 1.2.1. Marcel 2.1.0 is outside that constraint. Recheck when Rails changes its supported major. [Active Storage dependencies](https://rubygems.org/gems/activestorage/versions/8.1.4.1) · [Marcel releases](https://rubygems.org/gems/marcel)

The Render Blueprint selects PostgreSQL 18, the highest major available to new managed instances on the verification date. Render supplies the minor updates. Its Docker services use the same Ruby image as local Compose. [Render PostgreSQL versions](https://render.com/docs/postgresql-upgrading) · [Blueprint fields](https://render.com/docs/blueprint-spec)

On 24 November 2026, the repository Blueprint passed Render’s published JSON Schema with zero validation errors. The check parsed YAML with PyYAML 6.0.3 and validated Draft 2020-12 with jsonschema 4.25.1. The schema SHA-256 was `6c6721a602ef6d368d5c9384c473cefaae99980e43dd4b1adcf8a2f258fc54f4`. [Published Render schema](https://render.com/schema/render.yaml.json)

A fresh instance of the official `postgres:18.7-trixie` image applied all 12 application and queue migrations to an empty database. PostgreSQL reported server version 180007. The production Puma health endpoint returned HTTP 200. Solid Queue registered its scheduler, dispatcher and worker, including the Search Console catch-up job scheduled every 15 minutes. The Rails suite passed 50 tests and 434 assertions. The check ran in an isolated local Docker network namespace with external providers disabled. Render workspace permissions and hosted provisioning require an actual Render deployment. [PostgreSQL 18.7 release](https://www.postgresql.org/docs/release/18.7/)

## Checking for updates

From a built checkout, run `docker compose run --rm --no-deps web bin/check-dependencies`. The command reads the lockfile and consults RubyGems, Ruby and PostgreSQL. Exit 0 means all checked versions match, 1 means updates are available and 2 means at least one source could not be verified. Review Render's supported majors separately before changing its Blueprint. [RubyGems API](https://guides.rubygems.org/rubygems-org-api/)

When updating, review upstream release notes, refresh the lockfile with the selected Bundler and preserve its checksums. Compare Solid Queue's shipped schema with the application migrations. Rebuild the image, run the Rails suite on an isolated database, and verify worker startup before deploying.
