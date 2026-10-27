// Read-only release gate. This script never changes repository/provider settings.
import { pathToFileURL } from 'node:url';

export function validateReleaseContext({ ref, sha, releaseSha, confirmation }) {
  if (ref !== 'refs/heads/main') throw Error('Production releases must run from main.');
  if (!/^[a-f0-9]{40}$/.test(releaseSha || '') || releaseSha !== sha) {
    throw Error('release_sha must exactly match this workflow run commit. Review that full SHA before dispatch.');
  }
  if (confirmation !== 'I APPROVE PRODUCTION DEPLOYMENT') {
    throw Error('Explicit production deployment approval is required.');
  }
}

export function validatePagesControls(pages, environment) {
  if (pages.build_type !== 'workflow') {
    throw Error('Pages still publishes from a branch. Owner must select GitHub Actions in Settings > Pages before release.');
  }
  const reviewers = environment.protection_rules?.find(rule => rule.type === 'required_reviewers');
  if (!reviewers?.reviewers?.length) {
    throw Error('Configure a required reviewer for the github-pages environment before release.');
  }
}

export async function preflight(env = process.env, request = fetch) {
  validateReleaseContext({ ref: env.GITHUB_REF, sha: env.GITHUB_SHA, releaseSha: env.RELEASE_SHA, confirmation: env.CONFIRMATION });
  if (!env.GITHUB_TOKEN || !/^[\w.-]+\/[\w.-]+$/.test(env.GITHUB_REPOSITORY || '')) {
    throw Error('GitHub repository metadata/read access is required; no deployment was attempted.');
  }
  const api = env.GITHUB_API_URL || 'https://api.github.com';
  const read = async path => {
    const response = await request(`${api}/repos/${env.GITHUB_REPOSITORY}/${path}`, {
      headers: { Authorization: `Bearer ${env.GITHUB_TOKEN}`, Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28' },
      signal: AbortSignal.timeout(15000),
    });
    if (!response.ok) throw Error(`Cannot verify ${path} (HTTP ${response.status}). Stop; do not bypass the release gate.`);
    return response.json();
  };
  const [pages, environment] = await Promise.all([read('pages'), read('environments/github-pages')]);
  validatePagesControls(pages, environment);
  console.log('Release gates verified: exact main commit, manual approval, Actions publishing and required environment reviewer. No settings changed.');
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  preflight().catch(error => { console.error(error.message); process.exitCode = 1; });
}
