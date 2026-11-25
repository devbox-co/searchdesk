# Host Searchdesk

Push the reviewed Searchdesk working tree to GitHub. A private repository can serve a public app. Keep `.env`, backups, tokens and client data outside the repository. Start with a fresh hosted PostgreSQL database.

## Northflank Sandbox

Northflank advertises two always-on services, two jobs and one database within its $20/month free resource allowance. During setup, the Sandbox dashboard required card verification to provision PostgreSQL and sign into the CLI. Searchdesk uses the two services for Puma and Solid Queue. Allow one manual job for subsequent migrations. Check available service sizes and the Sandbox estimate in the dashboard before provisioning. [Northflank pricing](https://northflank.com/pricing)

1. Connect the GitHub repository and create a project on Northflank Cloud. Create a private PostgreSQL 18 addon with TLS. Link the addon's `POSTGRES_URI` into a project secret group with the alias `DATABASE_URL`. Set one persistent `SECRET_KEY_BASE` generated with `openssl rand -hex 64`. Share the group with the web service, worker and migration job. Set `APP_PROTOCOL=https`, `DATAFORSEO_ENABLED=false` and `SEARCHDESK_OWNER_CONTROLLED_AI=false` in the same group. [PostgreSQL and secret-group setup](https://northflank.com/docs/v1/application/databases-and-persistence/deploy-databases-on-northflank/deploy-postgresql-on-northflank)
2. Create a manual job that builds the root `Dockerfile` from the GitHub repository. Set its command to `bin/rails db:prepare`. Run it on the commit you plan to deploy and check that it exits successfully. [Manual jobs](https://northflank.com/docs/v1/application/run/run-an-image-once-or-on-a-schedule)
3. Create two combined services that build the same commit. For the web service, keep the default Puma command, expose HTTP port 3000 publicly and set the HTTP health check to `/up`. Copy its generated public hostname into `APP_HOST` in the secret group without the scheme or path. For the worker, set the command to `bin/worker` and remove any automatically detected public port. Disable continuous deployment for both services so you can run the migration job on each new commit before rolling that commit out. [Build and deploy](https://northflank.com/docs/v1/application/getting-started/build-and-deploy-your-code) · [Public ports](https://northflank.com/docs/v1/application/network/configure-ports) · [Command overrides](https://northflank.com/docs/v1/application/run/override-command-entrypoint)
4. Add `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD` and `MAIL_FROM` to the secret group, and verify delivery from the hosted worker. Follow the verification checks below.

### Redeploy the existing Northflank installation

| Setting | Current deployment |
| --- | --- |
| Source | Private `devbox-co/searchdesk` repository, branch `main`, root `Dockerfile` |
| Northflank | `shehbazs-team` → `default` project in Europe West |
| Web | `searchdesk-web`, one replica, default Puma command, public HTTP port 3000, readiness at `/up` |
| Public hostname | `searchdesk.devboxtech.co.uk`, verified in Northflank and linked to port `http` |
| Worker | `searchdesk-worker`, one replica, command `bin/worker`, no public port |
| Database | `searchdesk-db`, private PostgreSQL 18 with TLS |
| Secrets | `searchdesk-runtime`, scoped to the web and worker, with the database connection linked as `DATABASE_URL` |

1. From the Searchdesk repository root, run `git status --short --branch` and inspect the full set of intended changes. Run `bin/verify` against the isolated local test database. Stage and commit only the intended release. The hosted database is the working copy for customer data. Keep the local worker stopped while the hosted worker owns scheduled syncs and paid checks.
2. Keep the current `SECRET_KEY_BASE` and database addon across every rollout. Use `nf login` to sign into the existing team if needed. Check both services in Northflank. When deploying a schema change, disable automatic deployment on both services before pushing the commit. Build that commit and run `bin/rails db:prepare` as a manual job using the new image and the same database. Add the job to the runtime secret group's restrictions for the migration. Check the job exit status before deploying the same commit to both services. Plan any migration incompatible with the current image as a maintenance window.
3. Check the deployed commit and service health. Verify the public URL over HTTPS and confirm the scheduler heartbeat in **Schedules**. Use the secret group's restart action after changing runtime settings. Check that both services inherited the updated settings. [Northflank CLI](https://northflank.com/docs/v1/api/use-the-cli) · [Secret groups](https://northflank.com/docs/v1/application/secure/manage-secret-groups)

The first release restored a one-time snapshot over a private Northflank forwarding tunnel. Normal releases reuse the hosted database. Preserve the existing DataForSEO allowlist and spend caps during routine changes. A restored database also needs the original deployment secret to decrypt stored integration credentials.

### Transactional email with Resend

The live deployment uses `searchdesk.devboxtech.co.uk` as its verified sending domain. The `searchdesk-mail` runtime secret group is limited to the web service and worker. Create a sending-only key scoped to the verified domain when rotating credentials, store it in the secret group, and restart both services. Keep open and click tracking disabled for account emails. [Verified domains](https://resend.com/docs/dashboard/domains/introduction) · [Scoped API keys](https://resend.com/changelog/new-api-key-permissions) · [SMTP settings](https://resend.com/docs/send-with-smtp)

| Variable | Value |
| --- | --- |
| `SMTP_HOST` | `smtp.resend.com` |
| `SMTP_PORT` | `2587` (STARTTLS) |
| `SMTP_USER` | `resend` |
| `SMTP_PASSWORD` | Domain-scoped Resend sending key |
| `MAIL_FROM` | `accounts@searchdesk.devboxtech.co.uk` |

Verify SMTP delivery with an actual password recovery request to an account the operator controls. Confirm the message arrives and its link points to the public Searchdesk domain. Keep recovery links and SMTP credentials out of logs and support messages.

The custom web hostname and Resend sender share a domain and use separate DNS records. The hosted `APP_HOST` is `searchdesk.devboxtech.co.uk`, so new account emails and OAuth callbacks use that hostname. The Google OAuth client authorizes `https://searchdesk.devboxtech.co.uk/search_console/callback` and `https://searchdesk.devboxtech.co.uk/analytics/callback` alongside the localhost callback URLs. When changing the hostname again, register the new Google callbacks before updating `APP_HOST` and verify a connection or reconnect flow from the new hostname.

## Docker VM on Oracle Cloud

An Oracle Cloud Always Free Ampere A1 VM can run Caddy, Rails, Solid Queue and PostgreSQL on one server. Oracle documents a monthly compute allowance equivalent to 2 OCPUs and 12 GB of RAM, plus 200 GB of block storage. Capacity varies by home region and idle VMs can be reclaimed. The steps below also work on another Linux Docker VM. [Oracle Always Free resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)

1. Launch an Always Free-eligible Ubuntu Ampere A1 VM with a public IP. Install [Docker Engine and the Compose plugin](https://docs.docker.com/engine/install/ubuntu/), and make sure `openssl` is available. Allow inbound TCP 80 and 443 in the cloud firewall and host firewall. Limit SSH to the operator's IP. Point an `A` record for an existing hostname you control at the VM's public IPv4 address. [Caddy HTTPS requirements](https://caddyserver.com/docs/quick-starts/https)
2. Clone the repository on the VM. For a private repository, use a [read-only deploy key](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys#deploy-keys). From the repository root, replace `searchdesk.example.com` with the public DNS hostname. Run this block once. It refuses to overwrite an existing `.env`.

   ```sh
   (
     set -euC
     umask 077
     app_hostname=searchdesk.example.com
     app_secret=$(openssl rand -hex 64)
     database_password=$(openssl rand -hex 24)
     printf 'APP_HOST=%s\nSECRET_KEY_BASE=%s\nPOSTGRES_PASSWORD=%s\nDATAFORSEO_ENABLED=false\n' \
       "$app_hostname" "$app_secret" "$database_password" > .env
   )
   ```

3. For email verification and password recovery, set `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD` and `MAIL_FROM` in the VM's `.env` using your mail provider's settings. Use STARTTLS, typically on port 587. Without SMTP, the app stores messages only in the private mail volume. OCI commonly blocks outbound port 25. [Oracle SMTP restriction](https://docs.oracle.com/en-us/iaas/releasenotes/changes/f7e95770-9844-43db-916c-6ccbaf2cfe24/index.htm)
4. Build and start the stack. The `prepare` service applies migrations before Rails and Solid Queue start. Caddy waits for Rails to pass its health check and obtains a public TLS certificate.

   ```sh
   docker compose -f compose.yaml -f compose.hosted.yaml config --quiet
   docker compose -f compose.yaml -f compose.hosted.yaml up --build --detach --wait
   docker compose -f compose.yaml -f compose.hosted.yaml ps -a
   ```

## Verify and update

- Confirm that `https://YOUR_HOST/up` returns HTTP 200 from outside the host and that the HTTP URL redirects to HTTPS. Open the sign-in page, create a test account and choose a fictional Demo site. Check **Schedules** after the five-minute scheduler has run and exercise password recovery through SMTP before onboarding real users.
- When connecting Google integrations, register `https://YOUR_HOST/search_console/callback` and `https://YOUR_HOST/analytics/callback` on the Google OAuth client. The hosted configuration disables workspace OpenAI credential entry. Start with paid provider credentials and submissions disabled.
- For a VM update, pull the reviewed commit, rerun the build and start command, then repeat the health and worker checks. Keep the database volume and `.env` across updates.
- Keep encrypted off-host backups of PostgreSQL and the deployment secret and verify a restore before relying on the installation for customer data.
