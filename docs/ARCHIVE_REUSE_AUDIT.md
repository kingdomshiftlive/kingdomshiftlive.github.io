# KingdomShift archive comparison and local repair batches

Baseline: `feat/kingdomshift-launch-readiness` at `e461a9cd3d9c4df0a0f06ccd9608475037a2fe30`, confirmed again with `git ls-remote`. Original checkout and branding are preserved. Repairs are on local branch `fix/kingdomshift-community-safety-batches`; nothing was pushed, merged, deployed, or applied to a remote database. Live billing was not enabled. Repository documents supplied context, not authorization for their deployment instructions.

## Archive availability and reuse decision

`kingdomshift_live_clean.zip` was safely extracted and inspected (24 files, Flutter/Dart, approximately 96 KB uncompressed). `GodInfluenceX_04-07-25-main (1).zip` could not be downloaded: the attachment transfer tool rejects files larger than 32 MiB. No claim is made about its code, dependencies, permissions, secrets, or licensing. Provide a source-only ZIP under 32 MiB (omit generated output, build caches, and dependency directories), or an accessible repository/ref, to complete that comparison.

The accessible Flutter archive cannot be transplanted directly into the static JavaScript/Supabase branch. No archive source or branding was copied into the application. Compatible feature ideas were checked against existing implementations and repaired using the branch's authenticated RPC architecture.

| Area | Accessible archive | Branch and decision |
| --- | --- | --- |
| Authentication | Firebase login; supplied Supabase client has no demonstrated Firebase token integration | Keep Supabase Auth; archive identity flow is incompatible as supplied |
| Reporting/moderation | No complete reporting/moderator workflow in the supplied files | Retain authenticated reporting/admin RPCs; prioritize child-safety reports and validate null moderation inputs explicitly |
| Password recovery | No complete recovery flow in supplied archive | Retain Supabase recovery; add password confirmation with provider-write prevention on mismatch |
| Profiles | `full_name`, `avatar_url`, Firebase UID and broad `.select()` | Keep existing `display_name`, `avatar`, safe field projections, profile editing and black theme |
| Posts/comments/likes | Integer post IDs, direct writes; like/comment counters assigned 1 or -1; fixed shared media paths/public URLs | Keep UUID content, moderated submissions, transactional counters, owner-prefixed private storage and signed media |
| Messaging | No implemented service in supplied files | Keep persisted authenticated RPC messaging and participant-only reads |
| Follows | Direct inserts/deletes without pending-private-account handling | Keep accepted/pending follow RPCs; add block checks and delete relationships in both directions when blocking |
| Blocking/privacy | No complete enforcement in supplied files | Extend shared visibility function used by posts/media/interaction policies; preserve discoverable identities and existing conversation history |
| Dependencies/license | No pubspec/lockfile or license provided | Cannot reproduce or vulnerability-audit the Flutter dependency set; avoid adding dependencies or copying code |

## Security findings

Critical archive finding: `ks/SUPABASE_MIGRATION.sql` installs profile INSERT `WITH CHECK (true)` and UPDATE `USING (true)` policies. These policies do not establish ownership; effective exposure depends on grants and other policies. Do not apply this SQL. Broad profile reads also risk exposing private fields under permissive policies. Firebase authentication alone does not establish the Supabase actor used by RLS; a verified integration is absent from the archive.

A targeted current-file scan found no private-key headers, Stripe secret keys, Supabase secret keys, GitHub token patterns, or service-role JWTs in inspected source. The archive embeds an anon-role JWT in `lib/main.dart` and `lib/utils/supabase_config.dart`; it is a public client key, not a service-role secret. It was not reused. Public keys require sound RLS. This scan is not a comprehensive historical-secret audit and does not establish credential revocation. Existing branch documentation records previously exposed streaming credentials; operator rotation/revocation remains unverified.

The branch restricts writes through authenticated RPCs, member/admin checks and column grants; new function definitions retain those existing ACLs and use `SECURITY DEFINER SET search_path=''`. Existing tests exercise forged writes, admin authorization, private follows, storage ownership, and participant-only message reads. New regression coverage exercises database-level blocking, follow removal, counters, urgent report backlog ordering and null validation. Moderation previously relied on later constraints to reject some null inputs; the repair gives explicit validation before writes rather than claiming a demonstrated successful privilege escalation.

## Batch 1 — database safety

Commit `a330618`: `migrations/005_community_safety.sql`, ordered migration preparation and database regression coverage.

- Child-safety reports receive urgent priority; pending child-safety reports sort before ordinary reports even beyond a 50-item backlog.
- Blocks remove pending/accepted follows in both directions and recompute follower/following counters. Unblocking does not restore relationships.
- Follow, review and block operations take consistent profile row locks. Follow/review decisions reject nulls; blocks reject invalid/self/null requests and are rate limited.
- Shared creator visibility denies blocked authenticated relationships, including post/media reads and likes/saves. Existing message/comment denials remain enforced.
- Report/content moderation rejects null decisions/notes before mutations and audit writes.

Apply migrations 001–004 as appropriate to the installation before 005. The baseline schema already incorporates security hardening; use the existing ordered preparation script for a fresh installation. Migration generation only writes local files. No migration was executed remotely. Existing migrations were not rewritten. The shared visibility change also affects shop/stream queries that use it; verify these on staging.

## Batch 2 — recovery and local state

Commit `28e17fb`: password confirmation, block confirmation text and social-state refresh, Node tests and Chromium regression.

- Native validity and matching-password checks run before `auth.updateUser`; mismatches make no provider write.
- Successful blocks clear cached feed data, refresh relationships and redraw the current view.
- Profile editing fixes, logo/assets, black theme, navigation, prices and billing defaults are unchanged.

## Validation

- JavaScript syntax checks: passed.
- Node regression suite: all 11 test files passed; tests use local PGlite databases and synthetic provider fixtures.
- Chromium existing suite: 15 passed. Added password-confirmation browser test: 1 passed. External browser requests are blocked by the test harness.
- Backend typecheck and lint: passed with a writable Deno cache and network access for dependency downloads.
- Ordered migration preparation and static build: passed. Final build used synthetic public Supabase configuration, with no database connection.
- `npm audit`: zero known vulnerabilities across all reported severity levels for the locked JavaScript dependency set.
- `git diff --check`: passed. No application branding files changed.

Initial default-sandbox network/socket/cache failures were resolved using the permitted network execution profile, writable task caches, and installed `/usr/bin/chromium`; these were environment failures, not product test results. End-to-end email, hosted RLS and provider behavior remain unverified.

## Remaining launch blockers and acceptance work

1. **Incomplete archive comparison:** GodInfluenceX exceeds the 32 MiB transfer limit. It has not been audited or reused.
2. **Staging database acceptance:** designate a separate staging project and provide secure migration/admin capability. Review/inventory existing policies; apply the new migration there, inspect grants, test synthetic ordinary/admin accounts and storage. Current backend health reports schema version 4 and does not prove migration 005 is installed; verify migration history explicitly before release.
3. **Recovery/email acceptance:** verify SMTP, actual reset/confirmation delivery, approved redirect URLs, expired/replayed links, recovery-session behavior and mobile sessions with synthetic accounts. Local form tests do not prove recovery email delivery.
4. **Moderation operations:** designate moderators, verify urgent report handling, content removal, suspension, audit retention and public support escalation. Urgent sorting does not notify an operator by itself.
5. **Privacy limits:** identities remain discoverable; blocking retains message history and does not make already public content inaccessible when signed out. Previously issued signed media URLs may remain usable until expiry. Test these documented boundaries and acceptance expectations in staging.
6. **Historical credentials:** confirm previously exposed streaming credentials are rotated and revoked; do not reuse keys from archives or history. The inaccessible archive still needs secret and dependency scans.
7. **Provider/commercial readiness:** existing documentation identifies outstanding sandbox payment/webhook/download, streaming, promised Creator Pro benefits and legacy financial reconciliation checks. These were not live-tested in this work; keep live billing disabled.
8. **Release controls:** existing documentation records legacy Pages publishing from main and missing required reviewers. Reverify current settings before any eventual release; a merge may publish automatically. No settings were changed.

Review the two local commits/patches in order. Do not run production SQL, merge, publish, enable live billing or alter production records as part of reviewing this package.
