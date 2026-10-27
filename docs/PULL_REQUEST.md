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
