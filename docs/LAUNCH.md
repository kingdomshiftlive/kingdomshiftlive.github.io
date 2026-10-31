# Controlled launch and rollback

**Default state: live billing off, streaming off, erasure processing off, no automatic production deployment.** Pricing approval does not change this. Every production command below requires explicit owner approval before execution.

Current remaining-work priority and evidence: [LAUNCH_COMPLETION.md](LAUNCH_COMPLETION.md).

## 1. Review and stage

1. Review the feature branch, migrations, customer flows, commercial settings, and retention/operations procedures. Confirm that no approved branding or guide has been replaced.
2. Rotate the exposed Zego AppSign/server credentials through Zego. Removing them from current files does not remove Git history or old deployments. Use a fresh **32-byte ServerSecret**, not the old AppSign.
3. Create/select a separate Supabase staging project with synthetic users. Keep production customer data out of tests. Take a verified production backup before any later production migration.
4. Install the pinned tools and run `npm run prepare:db`. For a new staging database, apply the five generated migrations in order. The baseline includes migration 001. For an existing database, inventory actual tables, policies, functions, grants, and migration history; apply migration 001 and outstanding 002–005 through the reviewed path. Do not blindly rerun baselines, reset a customer database, or mark unexecuted migrations as applied.
5. Apply `supabase/storage.sql` **after all application migrations**. Inspect other pre-existing Storage policies: PostgreSQL permissive policies combine with OR, so unknown policies can override these restrictions. Confirm no public bucket or broad pre-existing policy bypasses the intended access rules. Storage operations are tested against modeled policies locally; the managed service requires staging verification.
6. Assign an administrator to a designated staging profile using authorized database-owner tooling. Public users cannot edit their own role. Check that a normal user cannot execute admin RPCs, read another account's messages/balance, write entitlements, or download unpaid files.

The CLI equivalents are `supabase link`, `supabase db push --dry-run`, then (only after review/approval) `supabase db push` against the intended project. Use a pinned/current official CLI. These commands have not been executed against production here.

## 2. Configure staging services

Use `.env.example` as the variable-name checklist. Never commit actual values.

| Destination | Configuration |
|---|---|
| Website build | `PUBLIC_SUPABASE_URL`, public anon/publishable `PUBLIC_SUPABASE_ANON_KEY`; never a service-role key |
| Supabase Auth | Site URL, allowed confirmation/recovery redirects, SMTP, email confirmation, signup limits/CAPTCHA and abuse controls |
| Edge runtime | `SITE_URL`, exact `ALLOWED_ORIGINS`; Supabase injects URL/service-role credentials |
| Stripe staging | `STRIPE_SECRET_KEY` using `sk_test_…`, `STRIPE_WEBHOOK_SECRET`, `BILLING_MODE=test`; configure the hosted customer portal |
| Database staging | Set `platform_settings.payment_environment` to `test` in the synthetic staging project; do not mix sandbox payments with a production ledger |
| Creator Pro | `PRO_ENABLED=false` until plan-benefit acceptance; approved price remains $19/month |
| Zego | Approved `ZEGO_APP_ID`, rotated `ZEGO_SERVER_SECRET`, provider room/token privileges; keep `STREAMING_ENABLED=false` until acceptance |
| Deletion | Keep `DELETION_PROCESSING_ENABLED=false` until retention/financial settlement review is approved |

Deploy the `platform` Edge function to the authorized **staging** project using `supabase functions deploy platform --project-ref <staging-ref>`. The function configuration disables the gateway JWT check solely because Stripe webhooks are public; each customer route validates its bearer token through Supabase Auth, then verifies profile state and ownership. Webhooks require a valid Stripe signature.

Stripe webhook destination: `<staging Supabase URL>/functions/v1/platform/webhook`.
Subscribe to: `checkout.session.completed`, `checkout.session.async_payment_succeeded`, `checkout.session.async_payment_failed`, `checkout.session.expired`, `customer.subscription.updated`, `customer.subscription.deleted`, `invoice.paid`, `invoice.payment_failed`, `charge.refunded`, and `charge.dispute.created`.

The backend `/health` route must report schema version readiness and the intended staging capabilities before UI acceptance. A listening process alone is not acceptance.

## 3. Run staging acceptance

- Sign up two synthetic accounts, confirm email, sign in/out, recover a password, and edit a profile.
- Publish text and video; verify pending content is invisible to another account, review it as admin, play the media, edit/resubmit, and remove it.
- Like, save, comment, follow, approve a private follow, block/unblock messaging, and refresh/re-login to verify persistence and isolation.
- Verify notification preferences/read state and report failure/success. Confirm reports reach the real operator queue.
- Upload a digital resource, review it, complete **sandbox** checkout, replay the webhook, and verify one receipt/credit. Reject a forged signature, changed amount, wrong mode, unpaid download, foreign session, and reused request key.
- Exercise Pro checkout, failed invoice, cancellation, portal, and analytics authorization with sandbox data. Do not advertise unconfigured benefits.
- Test gift retries, insufficient coins, earnings rounding, withdrawal reservation, and refund/dispute review. Verify every balance against the ledger and provider receipt.
- With streaming explicitly enabled for staging, use two physical devices: camera/microphone permission denial, host start/end, audience restrictions, chat, reconnect, token renewal, heartbeat expiry, moderation/provider-side removal, and mobile background behavior. No real credentials were available to automate this provider acceptance here.
- Submit deletion, verify immediate public hiding and deactivation, test financial holds, approve a synthetic erasure, and verify Storage/auth removal and retry handling. Do not mark requests complete without actual removal.
- Verify 320/390 px mobile layouts and desktop keyboard journeys, zoom, headings, dialogs, contrast, legal/support links, sharing, install icons, HTTPS, and custom-domain configuration.

## 4. Final owner approval and production release

Do not proceed until the owner explicitly approves production migration, deployment, and live billing as separate actions.

Inspect the **actual existing Pages publishing source** first. If it currently publishes `main`/root, merging this PR may itself publish the unbuilt source. Keep the PR unmerged until the owner approves the publishing-source transition to GitHub Actions and the configured artifact. Adding a manual workflow does not disable a pre-existing branch-based Pages deployment. Read-only verification on October 26, 2026 (Hawaii) confirmed `build_type=legacy`, source `main` `/`, HTTPS enforced, and no custom domain. The `github-pages` environment has a branch-policy rule but no required-reviewer rule. These settings were not changed. See `STAGING_VERIFICATION.md`.

- Verify backups/restore procedure, rollback artifact, administrator access, moderation staffing, support mailbox ownership, refund/dispute and withdrawal procedures, and privacy/retention text.
- Reconcile all legacy coins, balances, roles, subscription flags and follower gates. Old client-writable fields cannot be assumed trustworthy.
- Verify the Android release package/certificate fingerprint in `.well-known/assetlinks.json`; the repository alone cannot prove its correctness.
- For `kingdomshift.live`, verify domain ownership, DNS, Pages configuration and HTTPS before setting a CNAME or changing canonical/social/sitemap/API redirect origins. The current source uses the existing GitHub Pages host.
- Apply reviewed production migrations/Storage policies, deploy the approved Edge function and set its secrets, then build the public artifact with the correct public project configuration.
- Production website deployment is the manual workflow `Controlled Pages deployment`. It requires the full reviewed main SHA as `release_sha`, the exact confirmation text and the protected `github-pages` environment. The read-only preflight rejects branch-based Pages publishing, absent required reviewers, other branches, unknown settings and mismatched SHAs; it rechecks publishing protections after environment approval. Configure required reviewers in repository settings; workflow code alone cannot create that protection.
- Live checkout additionally requires `BILLING_MODE=live`, a matching live Stripe key/webhook, `LIVE_BILLING_APPROVED=true`, and database `payment_environment=live`. Set none of these automatically. Streaming and erasure each have their own explicit flags.
- After release, verify the actual deployed build-info commit, root application, SDK assets, policy pages, auth redirects, capability endpoint, moderation queues and receipt processing. Any live payment smoke test requires its own explicit approval.

## Rollback and incident response

1. Stop new checkout first with `BILLING_MODE=disabled`. Keep the previously approved webhook key and database payment mode while already-paid receipts settle. Do not discard or acknowledge unprocessed payment events.
2. If ledger integrity is in question, disable financial RPCs by setting the database payment environment to `disabled` through authorized operator tooling, suspend affected accounts, and reconcile pending provider events before restoring service. Expect failed fulfillment events to retry during this hold.
3. Set `STREAMING_ENABLED=false` to stop new token issuance and follow the Zego console/provider procedure to terminate active broadcasts. Hiding a room is not immediate provider revocation.
4. Redeploy a verified **safe** website artifact and compatible Edge version. Never revert to the original exposed-credential/client-money code. Retain database hardening.
5. Prefer forward database fixes. A destructive down migration or point-in-time restore requires separate approval, validated backup, and reconciliation of all provider events/receipts since the restore point to prevent duplicate credits or missing money.
6. Keep deletion processing off during incident investigation. Requests remain in durable queues; do not claim completed deletion when authentication or files remain.

No rollback, production migration, provider charge, payout, or deployment is performed by these instructions.
