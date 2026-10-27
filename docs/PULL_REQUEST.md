## Problem and resulting behavior

The original client could fail at startup, render user data as executable HTML, expose streaming signing credentials, and simulate successful financial/deletion actions. The feature branch replaces those paths with authorized database operations, verified server payment receipts, production streaming tokens, real content/moderation/customer workflows, and truthful failure handling while preserving KingdomShift branding and owner-approved commercial settings.

## Scope

- Public/legal/navigation/accessibility repairs and pinned local SDKs.
- Auth/profile/recovery, moderated text/video content, persistent social interactions, private follows, messages, notifications, reporting and administration.
- Approved coin catalog, $19/month Pro lifecycle/analytics, digital catalog and receipt-authorized downloads, atomic gifts and reserved withdrawals.
- Restricted Edge API, reviewed SQL/Storage migrations, server-side Token04, capability/approval gates and optional erasure processing.
- Reproducible public build, CI checks and a manual protected Pages deployment workflow; environment checklist, acceptance procedure, network review and rollback plan.

## Validation and limits

Run `npm run check`, `npm run typecheck`, `npm run lint`, `npm test`, `npm run test:browser`, `npm run prepare:db` and `npm run build` with synthetic public configuration. Tests use isolated PostgreSQL and synthetic provider/browser fixtures. They do not prove real SMTP delivery, Zego sessions, Stripe account configuration, or deployed Supabase permissions. See `docs/STATUS.md` and `docs/VALIDATION.md` (37 Node tests and 14 browser tests passed).

## Release controls

No production SQL, live charge/payout, or production deployment has been executed. Pricing is approved; live billing and production release still require final owner approval. Do not merge/deploy until staging acceptance, legacy-balance reconciliation, credential rotation and operations review are complete. The network draft is for the development environment only and does not grant production authorization.

## Remaining launch work and merge protection

See `docs/LAUNCH_COMPLETION.md` for the ordered owner/operator checklist and the minimal community-only release option. Existing application work and validation evidence are preserved; only four targeted release-preflight tests were added and executed in this continuation.

The dispatch workflow now requires the exact reviewed main SHA, checks the actual Pages publishing source and required environment reviewer before checks, and rechecks protections after review. It fails closed on missing permissions or unknown settings. This does not disable existing legacy branch-based Pages publishing: the owner must switch Settings → Pages → Source to GitHub Actions before merging can be treated as nonpublishing. No merge, deployment, production-data change, provider-secret rotation or live billing activation was performed.
