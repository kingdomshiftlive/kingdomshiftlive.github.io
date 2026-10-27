# Network and credential access review

The proposed development-environment configuration remains **restricted**. Existing package-manager/Git presets are preserved. No wildcard Internet rule, secret value, production credential, or automatic deployment was added.

| Custom HTTPS destination | Why it is needed | Operations permitted for the current review |
|---|---|---|
| `api.github.com` | Inspect repository/PR/CI metadata and create the requested draft PR | Repository reads; feature-branch PR creation/update only |
| `kingdomshiftlive.github.io` | Verify the currently published site, headers, routes and resources | GET/HEAD only |
| `kingdomshift.live` | Verify the intended customer domain and any redirect from the Pages host | GET/HEAD only; no domain/DNS changes |
| `api.supabase.com` | Inspect project configuration and, later, perform explicitly approved staging/deployment operations | Read-only project inspection now; no production SQL, secret changes, or function deployment authorized by network access alone |
| `zyhkginxgjxzfhtckwdy.supabase.co` | Existing project's Auth, REST, Storage and function health endpoints | Read-only health/schema checks; no production data writes or customer-data tests |

`github.com` and the existing Git proxy hosts are already included by the retained preset. No new GitHub token is requested merely because API access failed. Browser/provider destinations for actual Zego sessions and `api.stripe.com` are not needed for the completed isolated tests and are not broadly opened by this draft. Authorize additional staging provider testing separately when credentials and endpoints are known. Do not add speculative wildcard rules.

## Minimum account permissions

- **GitHub:** use the existing repository-scoped integration when possible. Read Contents/metadata to inspect; write Contents on the feature branch and write Pull requests to publish the requested review. Updating the included workflow files may require repository Workflows write. Read Actions/check results is useful for CI verification. No main-branch merge, administrator access, Pages deployment, production environment approval, or repository-secret changes are required to create the PR. A network denial is not proof that a replacement token is needed.
- **Supabase:** the public anon/publishable key suffices for public health checks, not administration. Project-configuration inspection requires an authorized management credential with access to the named project. Migration, Edge deployment and secret setup require project/database-owner capabilities **only for the separately approved target**, starting with synthetic staging. The Edge service-role credential is server-side and is supplied by Supabase; it must never be used in the browser or included in a PR.
- **Live site:** GET/HEAD requests need no customer account or payment permission. Authenticated acceptance should use designated synthetic accounts in staging. Do not reuse customer accounts or make a charge as a connectivity test.

## Current observed state

Git operations can read through the supplied HTTPS Git proxy. Earlier GitHub API, live-site and Supabase requests received `403 Forbidden` from the environment's CONNECT proxy. This establishes an egress restriction, not an application outage or invalid provider credential. The running process environment had no Supabase, Stripe or Zego credential bindings; configuration metadata declared no such secret bindings. Values were not printed or dumped.

The additive network draft was saved successfully and requires review/save in **development environment settings**, followed by publishing that development environment. Draft persistence does not apply the policy to the current machine, publish the website, or authorize production writes. Retry affected read-only operations after that meaningful runtime change; do not repeatedly retry unchanged failures.

## Remaining secure inputs

Public build configuration: project URL and anon/publishable key. Provider configuration: authorized Supabase staging/deployment access, Stripe sandbox key/webhook signing secret and portal, rotated 32-byte Zego ServerSecret and App ID, correct Auth email/redirect settings, and administrator assignment. Enter raw signing secrets in the provider's secure runtime settings; proxy-backed placeholders cannot be used as local cryptographic signing keys. Never paste secret values into chat.
