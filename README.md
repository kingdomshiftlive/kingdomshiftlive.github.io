# KingdomShift.Live website

This is a static GitHub Pages application. `index.html` at the repository root is the authoritative application. `ks_live_deploy/index.html` redirects old links to it; do not maintain or deploy a separate application from that directory.

## Development and checks

Use the existing checkout. Node 24 and Python 3.11+ are used in CI. No frontend build, payment credentials, or signing secrets are needed to serve the website.

```sh
npm ci --ignore-scripts
npm run serve
```

The development server binds to port 8000 on the local machine. It is for development only. GitHub Pages must publish the **main branch, repository root**, or an equivalent artifact containing these root files. No deployment or production database changes are performed by the test workflow.

```sh
npm test
python -m pip install -r tests/requirements.txt
python -m playwright install chromium
python -m unittest discover -s tests -p 'test_*.py' -v
npm audit --audit-level=moderate
```

If using an already installed Chromium, set `CHROMIUM_PATH` to its executable for the Python test command. Database tests use PGlite, an isolated PostgreSQL engine: they do not contact Supabase. Browser tests block external requests and use a fake database for authenticated operations. They cover real SDK loading, authentication startup/profile creation, navigation, legal pages, HTML injection, UUID controls, mobile layouts, keyboard navigation, report failures, payment safeguards, icons, redirects, and cache cleanup. They are not production integration tests.

The Supabase SDK is pinned to 2.118.0 in `package-lock.json` and served locally from `vendor/`. Its official npm tarball integrity was verified before vendoring. On a deliberate dependency upgrade, install and audit the exact version, replace the UMD bundle from `node_modules/@supabase/supabase-js/dist/umd/supabase.js`, retain its license, and update the HTML reference and regression integrity test together.

## Required production remediation

The source fixes do not rotate credentials, apply SQL, or publish GitHub Pages.

1. **Rotate the exposed Zego signing credentials/server secrets** in the provider dashboard. Treat the old values as compromised: they remain in Git history and previously deployed copies. They must never return to browser code. Confirm the rotation invalidates old credentials/tokens according to the provider's procedure.
2. Back up the Supabase database and verify changes in a staging project. For an **existing installation**, run `migrations/001_security_hardening.sql` as the database owner in Supabase SQL Editor. It is transactional and repeatable. For a **new installation**, run `supabase_schema.sql`, which includes the same hardening. Do not rerun the retired legacy live-stream SQL.
3. The migration deliberately replaces policies and client grants on the application tables. Client writes to balances, coins, follower counts, subscriptions, verification, roles, streams, gifts, scores, withdrawals, and content publishing are disabled. Display/profile preferences, safe profile creation, and detailed reports remain available. Review native clients and other services that may have depended on the old permissive grants before applying it. Trusted server services must replace those operations rather than restoring broad grants. The application requires the new `get_my_settings()` function and report fields.
4. Deploy the reviewed website changes. Verify GitHub Pages source, HTTPS, the root application and SDK, policy pages, icons, `.well-known/assetlinks.json`, and a real authenticated account. Verify that another account cannot read email/private content or change financial/privileged fields. Test report receipt using a designated test account and inspect it through authorized administrative tooling.
5. Confirm the Android package name and certificate fingerprints in `.well-known/assetlinks.json` match the actual signed release. Their correctness cannot be established from this website repository. The old root `assetlinks.json` remains for compatibility.

No changes have been pushed or published by these instructions. Production headers, provider settings, email delivery, Android verification, and real authenticated behavior require production access to verify.

## Features awaiting a trusted backend

New coin/Pro purchases, gifting, withdrawals, streaming, shop checkout, playback, messaging, and persistent social interactions are explicitly unavailable or labeled as previews. Disabled financial actions never grant value, accept payment, or write to a financial table. The website previously simulated those successes; those fallbacks have been removed. Practice quiz scores and feed likes/follows/saves last only for the current visit and provide no financial rewards.

To enable these features safely, implement and test authenticated server operations with server-owned product/pricing configuration, verified idempotent payment webhooks, an atomic ledger, authorization and rate limiting, approved withdrawal handling, and short-lived server-issued streaming tokens. Streaming signing credentials and Supabase service-role keys belong only in backend secret storage. GitHub Pages cannot host those backend endpoints. Do not re-enable the old client signing or demo-value code.

Private accounts are currently visible **only to their owner**, including published content. There is no approved-follower system yet. Privacy preferences are read through an owner-only function; emails come from Supabase Auth and are not selectable through the public profile API. Existing stored email columns are retained to avoid destructive data changes, but client access is revoked.

Reports require sign-in, a content/profile URL, a concern category, and details. They are account-linked, not anonymous, and acknowledge success only after a confirmed insert. Operators must monitor the reports table through authorized tools and maintain a real moderation/escalation process. The code does not automatically notify moderators or law enforcement.

Account deletion uses a clearly labeled email link to the existing published support address, `kingdomshiftmedia@gmail.com`. Opening it does not send an email or delete data. Operators must monitor that mailbox, verify ownership, and process requests; automated account deletion is not implemented.

## Deployment and caching

The service worker retires the old `ks-v*` caches and does not intercept requests. Deployments therefore use normal HTTP behavior rather than retaining an indefinitely cached application. Public legal hashes work without login; `404.html` recognizes the old legal paths and shows a real not-found page for unknown routes. Old stream-sharing query strings cannot start a stream while streaming is unavailable.

Metadata and sitemap currently use `https://kingdomshiftlive.github.io/`. If publishing on a verified custom domain, update canonical, social-image, robots, sitemap, and policy links together. No custom-domain configuration is assumed.
