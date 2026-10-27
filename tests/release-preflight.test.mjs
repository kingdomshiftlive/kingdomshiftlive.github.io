import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { validateReleaseContext, validatePagesControls, preflight } from '../scripts/release-preflight.mjs';
const sha = 'a'.repeat(40);
const context = { ref: 'refs/heads/main', sha, releaseSha: sha, confirmation: 'I APPROVE PRODUCTION DEPLOYMENT' };
const pages = { build_type: 'workflow' };
const environment = { protection_rules: [{ type: 'required_reviewers', reviewers: [{ type: 'User', reviewer: { id: 1 } }] }] };

test('release rejects unreviewed commits, other branches and missing approval', () => {
  assert.doesNotThrow(() => validateReleaseContext(context));
  for (const change of [{ ref: 'refs/heads/feature' }, { releaseSha: 'b'.repeat(40) }, { releaseSha: 'main' }, { confirmation: '' }]) {
    assert.throws(() => validateReleaseContext({ ...context, ...change }));
  }
});
test('branch publishing and missing environment reviewers block deployment', () => {
  assert.doesNotThrow(() => validatePagesControls(pages, environment));
  assert.throws(() => validatePagesControls({ build_type: 'legacy' }, environment));
  assert.throws(() => validatePagesControls(pages, {}));
  assert.throws(() => validatePagesControls(pages, { protection_rules: [{ type: 'required_reviewers', reviewers: [] }] }));
});
test('unreadable provider settings fail closed without exposing the token', async () => {
  const env = { GITHUB_REF: context.ref, GITHUB_SHA: sha, RELEASE_SHA: sha, CONFIRMATION: context.confirmation, GITHUB_REPOSITORY: 'owner/repo', GITHUB_TOKEN: 'synthetic-token' };
  const calls = [];
  const request = async (url, options) => { calls.push({ url, method: options.method || 'GET' }); return { ok: false, status: 403 }; };
  await assert.rejects(preflight(env, request), error => /HTTP 403/.test(error.message) && !error.message.includes(env.GITHUB_TOKEN));
  assert.equal(calls.length, 2);
  assert(calls.every(call => call.method === 'GET'));
});
test('production workflow is manual, SHA-pinned, protected and gated twice', async () => {
  const workflow = await readFile('.github/workflows/deploy-pages.yml', 'utf8');
  assert.match(workflow, /workflow_dispatch:/);
  assert.doesNotMatch(workflow, /^\s*(push|pull_request|workflow_run|schedule):/m);
  assert.match(workflow, /release_sha:/);
  assert.match(workflow, /name: github-pages/);
  assert.equal((workflow.match(/run: node scripts\/release-preflight.mjs/g) || []).length, 2);
  assert.equal((workflow.match(/ref: \$\{\{ github.sha \}\}/g) || []).length, 2);
  assert.doesNotMatch(workflow, /BILLING_MODE|LIVE_BILLING_APPROVED|supabase db push|functions deploy/);
});
