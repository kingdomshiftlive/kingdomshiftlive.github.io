# Launch completion: remaining work only

Prepared October 27, 2026 (Hawaii), continuing Draft PR #1 at `7eca1e5`.
All six existing PR commits are preserved. No merge, deployment, provider-secret
change, production SQL, production data change, or live billing activation is
part of this preparation. Pricing and splits remain exactly as in `PRICING.md`.

## What is already done

Use the existing implementation and evidence in `STATUS.md`, `VALIDATION.md`, and
`STAGING_VERIFICATION.md`: authentication/recovery, community workflows, Stripe
receipt verification, financial RPCs, server Zego tokens, migrations, storage
policies, build and test tooling. The recorded 37 Node and 14 browser tests are
prior evidence, not rerun or represented as current real-provider acceptance.
Do not rebuild these features or repeat those suites before an actual change
or a failed acceptance check justifies it.

The Android 1.0.5 screenshots show Twin and video-call features. This repository
and `build-twin` do not establish the complete native app's source or release
signing identity. The uploaded ZIP exceeds this execution tool's 32 MiB transfer
limit and could not be inspected. Website release does not prove an Android
store/APK update, working private video calls, or Twin feature parity. Keep the
installed app and its data intact; native distribution remains a separate gate.

## Prioritized exit gates

| Order | Minimum outcome | Work I can do without credentials | Owner/operator prerequisite and evidence |
|---|---|---|---|
| 0: prevent accidental publication | Merging changes cannot publish the raw source | Added dispatch-only exact-commit preflight, Pages-source verification, and required-reviewer verification; failure blocks release | In Settings > Pages choose **GitHub Actions** instead of branch publishing. In Settings > Environments > github-pages configure a required reviewer. Do not dispatch a deployment. Last verified source was main/root; today's API read is HTTP 403, so current settings are not re-certified. |
| 1: separate staging | One explicitly confirmed synthetic-only staging destination with compatible schema | Removed old project assumptions from `.env.example`; prepared read-only inventory below and retained existing migrations | Candidate from owner: `kingdomshiftlive-staging`, ref `jsraezhloekelhuzehou`. Confirm its identity and secure staging access before any writes. Production `cotcogrkmtgibbpwhxrg` must not be used as staging. Inspect existing UUID/full_name schema, trigger ownership, grants, and migration history before applying the text/display_name baseline. Never blindly apply/rewrite/reset it. |
| 2: usable accounts/community | Two synthetic users can confirm email, sign in/out, recover/change passwords, edit profiles, exchange authorized messages and use content/reporting flows; a third designated synthetic admin can moderate | Implementation is already in PR #1; diagnose and patch only a failed staging case | Configure public staging build variables, provider Auth redirects and secure SMTP; provide synthetic mailboxes and staging migration access through secure settings. Apply only the reviewed compatible staging migrations, Storage policies, and Edge function. Record managed-service outcomes, not mock results. |
| 3: revoke exposed credentials | Previously exposed signing credentials no longer work | Current PR removes them and uses server Token04; no browser secret is required | Rotate Zego AppSign/ServerSecret and revoke old credentials in the provider console; review other actually exposed secret credentials. Public Supabase publishable/anon and Stripe publishable keys are not server secrets. Store replacements only in staging Edge secrets. Rotation/revocation evidence is required before streaming. Do not rotate production credentials without the owner's explicit approval and coordination with the installed app. |
| 4: Stripe sandbox | One complete approved-catalog sandbox order, webhook, receipt, credit/download plus duplicate/invalid event and refund/dispute checks | Existing signed fulfillment and catalog remain unchanged; no new billing code is needed without a failed case | Secure `sk_test_...` and staging webhook secret; configure webhook and portal. Staging Edge `BILLING_MODE=test`, database `payment_environment=test`. Keep `LIVE_BILLING_APPROVED=false`; do not connect test receipts to a production ledger. |
| 5: Creator Pro promise | Benefits actually match the approved $19/month offer | Existing entitlement lifecycle and owner-only analytics are present; enrollment can stay off | Accept intended benefits and supply intended simulcast/priority-CDN services if promised. Test checkout, renewal failure, cancellation and revocation in sandbox only. Do not charge for unavailable benefits or alter the approved price to work around them. |
| 6: Zego acceptance | Authorized host/audience stream works on two devices, including denial/reconnect/renewal/moderation/end | Server token authorization, role restrictions and heartbeat leases are implemented | Configure rotated credentials and room privileges on staging; explicitly enable staging streaming only for this test. Test actual media and provider-side immediate removal. Then disable it again until release approval. A stream test is not proof of private video-call/Twin readiness. |
| 7: financial reconciliation | Operator signs off on opening balances, receipts, ledger, liabilities and subscription entitlements | Prepared reconciliation worksheet; existing atomic settlement code is retained | Authorized operator supplies aggregate reconciliation from trusted provider records and read-only database reports, without copying customers into tests. Resolve discrepancies; do not assume legacy client-writable balances/roles/follower gates are trustworthy. Production adjustments require separate approval. |
| 8: controlled release | Approved artifact, backend versions and rollback are identified, with owner approval for each production step | Added read-only release gates and exact-SHA workflow; existing rollback instructions remain | Review staging evidence, backup/restore and support/moderation staffing, domain/HTTPS, native identity if shipping Android, then separately approve production migration, Edge deployment, website deployment, and live billing. Approval of one does not approve the others. |

Staging access/credentials are not present in this execution environment. Do not
paste secret values in chat, SQL exports, issues, or PR comments. Use provider
secret settings and secure environment bindings. Merely naming a project or
saving configuration is not proof that staging is provisioned or accepted.

## Fastest honest initial release

A community-only web release can proceed after gates 0–3 and the nonfinancial
parts of gate 8 are accepted. Keep `BILLING_MODE=disabled`, database
`payment_environment=disabled`, `LIVE_BILLING_APPROVED=false`, `PRO_ENABLED=false`,
`STREAMING_ENABLED=false`, and `DELETION_PROCESSING_ENABLED=false`.
This is a reduced initial release, not a claim that every phone-app feature is
launched. Existing balances and paid entitlements must not be represented as
reconciled; keep financial actions disabled and avoid advertising their use.

Safe to defer with truthful availability labels and blocked backend operations:

- Coin purchases, paid digital checkout/download access, gifts and withdrawals.
  No simulated credits, fake receipts, invented balance resets or automatic payouts.
- New Creator Pro enrollment, simulcasting, priority CDN, audience subscriptions
  and tithes. Preserve approved pricing in the catalog; do not sell undelivered benefits.
  Existing subscriptions require operator review/support rather than disappearing.
- Live streaming and private calling/Twin features not accepted in the actual
  release codebase. Do not advertise a functioning call or broadcast button.
- Automatic erasure execution while retention/financial holds await approval.
  Deletion requests and a staffed response process must remain available; do not
  label deletion completed before authentication and files are actually removed.
- Mobile push, email digests and other unimplemented services. In-app notifications
  may be described as in-app only.

Enabled community features require working moderation, reports, legal/support
links and security isolation. These cannot be deferred while accepting users.
For a paid/streaming launch, gates 4–7 are mandatory, not post-launch cleanup.

## Reconciliation worksheet (operator-owned, no production writes)

Use one consistent cutoff and currency. Record provider account, database project,
mode and report timestamps; retain reports securely, with only aggregate evidence
in the release record. A script cannot certify legacy opening balances.

1. Compare trusted Stripe settled payments to paid `checkout_orders`, webhook
   `payment_events`, purchased products and `coin_ledger` checkout sources. Include
   pending/expired/failed orders and retries; one provider receipt earns one fulfillment.
2. For each account, verify opening approved coins + verified purchases − gifts
   and other approved debits = closing coins. Reconcile per account first; matching
   grand totals alone can hide offsetting errors. Do not invent opening ledger entries.
3. Verify creator earnings using approved gift/shop allocations and existing
   whole-cent rounding. Account separately for pending withdrawal reservations,
   completed provider payouts, refunds, disputes and unresolved incidents.
4. Compare actual processor fees/net settlements to the published allocation;
   preserve approved creator shares. Reconcile timing differences and withheld funds.
5. Match active/trialing/cancelled/delinquent Stripe subscriptions to
   `billing_subscriptions` and `is_pro`; verify roles and follower withdrawal gates
   against trusted data. A mutable legacy flag is not proof of a paid subscription.
6. Require zero unexplained differences, or an explicitly approved documented
   hold/resolution per exception. Do not unlock monetization or erase financial
   records until the operator signs off. Actual corrections need separate approval.

## Controlled deployment sequence

1. **Before merge:** owner disables legacy branch-based Pages publishing by
   selecting GitHub Actions; configures a required reviewer for `github-pages`;
   confirms no other active workflow publishes on push/merge. Existing Pages
   settings are external to Git and cannot be disabled by this PR's YAML alone.
2. Keep Draft PR #1 unmerged until staging evidence and the scope of the intended
   release are accepted. Retain all commits; no force-push/reset/rebase is needed.
3. Only after explicit owner merge approval, merge. Merge runs checks only under
   this PR's configuration; it does not dispatch the release workflow. This is
   contingent on step 1, not a promise that a YAML file controls legacy Pages.
4. After separate website-deployment approval, select **Controlled Pages deployment**
   on `main`, enter its full reviewed 40-character SHA as `release_sha`, and type
   `I APPROVE PRODUCTION DEPLOYMENT`. A stale SHA or other branch is rejected.
5. The workflow reads actual Pages/environment protections, runs existing checks,
   waits for environment review, rechecks protections and publishes only `dist/`
   from that same SHA. Unknown/403 settings fail closed. No skip flag or publish-on-merge
   fallback exists. It does not migrate Supabase, deploy Edge functions or enable billing.
6. Verify deployed `build-info.json`, health/capabilities and the accepted scope;
   monitor auth/report/support queues. Rollback follows `LAUNCH.md`, never the old
   exposed-credential/client-money source. Live billing remains a separate approval.

## Changes and evidence in this continuation

- Continued PR #1 at `7eca1e5`; preserved the complete prior ancestry and separate
  local auth-repair branch. No old development work was replayed into PR #1.
- Added `scripts/release-preflight.mjs` and wired it before checks and after review.
  Targeted new tests: **4 passed**, no failures/skips. Deployment YAML parsed.
  Previously completed application/browser suites were not rerun.
- Replaced stale hardcoded project identity in `.env.example` with explicit staging
  placeholders; real secrets remain outside Git.
- Added `docs/sql/staging-inventory.sql` (read-only catalog inspection; not executed
  remotely). This is preparation, not a completed managed migration.
- Current GitHub API reads return HTTP 403. Git transport permits fetching and
  branch publication; current Pages settings/PR metadata cannot be re-verified
  through the API here. Retained earlier verified observations with their dates.

## Next single owner action

Open the repository's **Settings → Pages → Build and deployment → Source**.
Change **Deploy from a branch** to **GitHub Actions** and save if prompted.
Do **not** merge PR #1 or click **Run workflow**. Reply when Source shows
**GitHub Actions**. This removes the known merge-triggered publishing hazard;
required-reviewer setup and staging access are the next gates, not assumed done.
