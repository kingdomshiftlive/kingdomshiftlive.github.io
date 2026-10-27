# KingdomShift.Live

Faith-centered community platform: **Stream With Purpose. Shift the World.** The approved dark, teal, gold, and pink branding is retained. The root application is authoritative; `ks_live_deploy/` redirects old links to it.

The code is prepared for owner review, **not deployed or approved for live billing**. See [launch instructions](docs/LAUNCH.md), [implementation status](docs/STATUS.md), and [approved pricing](docs/PRICING.md).

For the remaining prioritized release gates and the next single owner action, see
[Launch completion](docs/LAUNCH_COMPLETION.md). Existing implementation and test evidence are retained.

## Architecture

- Static HTML/CSS/JavaScript on GitHub Pages, with pinned browser SDKs served from `vendor/`.
- Supabase Auth for email signup, confirmation, sign-in, recovery, password changes, and session management.
- PostgreSQL RLS, bounded authenticated RPCs, owner-only account state, moderation queues, and private Storage buckets.
- `supabase/functions/platform/`: authenticated Edge API for Stripe checkout/webhooks/portal, receipt-authorized downloads, Zego production tokens, stream leases, and explicitly enabled erasure processing.
- No service-role, Stripe secret, or streaming signing key belongs in browser configuration. `app/config.js` is generated in the deployment artifact from **public** build variables.

## Local development

Use Node 24 and Python 3.11+. Work in the existing checkout.

```sh
npm ci --ignore-scripts
npm run prepare:db
npm run check
npm run typecheck
npm run lint
npm test
python -m pip install -r tests/requirements.txt
python -m playwright install chromium
npm run test:browser
```

`prepare:db` only generates ordered CLI files. It does not connect to a database. Tests use synthetic fixtures, isolated PostgreSQL/PGlite databases, fake provider calls, and blocked external browser requests. Set `CHROMIUM_PATH` to an existing Chromium executable when needed.

Supply `PUBLIC_SUPABASE_URL` and `PUBLIC_SUPABASE_ANON_KEY` from an authorized development/staging project through your shell or secure environment settings, then:

```sh
npm run build
python3 -m http.server 8000 --bind 127.0.0.1 --directory dist
```

The build refuses service-role or unrelated keys and excludes backend code, migrations, tests, environment files, and dependencies from the public artifact. Source `app/config.js` deliberately has no hardcoded key. Without public configuration, account features show an error; public legal pages remain available.

## Database and integrations

Canonical SQL lives in `supabase_schema.sql` and `migrations/`. `npm run prepare:db` copies these into ignored, timestamped `supabase/migrations/` files for the CLI. Existing installations already using migration 001 should apply only the outstanding changes after a reviewed baseline; never mark unexecuted SQL as applied.

Apply database and Storage changes to a synthetic staging project first. Follow the staged procedure in `docs/LAUNCH.md`. The test fixtures do not prove that production permissions, SMTP, Stripe products/webhooks, Zego room privileges, or existing customer records are correct.

Provider settings and required variables are listed in `.env.example`. Enter secret values only in the provider's secure settings. Supabase supplies its service-role key to deployed Edge functions. Do not paste credentials into chat, commit `.env` files, or treat a cloud proxy placeholder as a raw signing secret.

## Safety controls

- Live billing defaults to disabled. It additionally requires an explicitly matching database environment and `LIVE_BILLING_APPROVED=true` before live checkout is possible. Production deployment is manual and requires explicit confirmation.
- Old exposed Zego credentials must be rotated. Production tokens are generated server-side, limited in time, bound to a room/user, and restrict audience publishing.
- Posts and digital products require administrator review. Private content requires accepted follow access; media uses expiring URLs.
- Financial credits come from verified receipts, gifts are atomic/idempotent, and withdrawals reserve balances pending operator review. Payouts are not automatically transferred by this application.
- Refund/dispute events put purchases into review and suspend the buyer pending financial reconciliation. Operators must resolve the incident; the code does not silently invent refund clawbacks.
- Deletion requests are durable and deactivate access immediately. Optional erasure processing remains disabled until the owner approves retention procedures. It blocks unresolved subscriptions, orders, purchases, and balances, removes personal content/authentication, and retains pseudonymous accounting references.
- Practice quiz results are local and have no monetary rewards. No AI assistant or approved AI-guide asset exists in the supplied repository; no AI integration or replacement guide was invented.

## Dependency updates

Versions and integrity metadata are pinned in npm and Deno lockfiles. Supabase and Zego browser bundles match the locked npm artifacts. Update the package, browser artifact, license, HTML/script reference, and matching integrity tests together. Keep signature/checksum/TLS verification enabled.
