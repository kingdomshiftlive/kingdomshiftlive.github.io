import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { Script } from 'node:vm';
const read = path => readFile(new URL('../'+path,import.meta.url));

test('vendored SDK exactly matches the locked official dependency', async () => {
  assert.deepEqual(await read('vendor/supabase-2.118.0.js'),await read('node_modules/@supabase/supabase-js/dist/umd/supabase.js'));
  assert.match((await read('vendor/supabase-LICENSE')).toString(),/MIT/);
});

test('fresh schema embeds the same hardening used for upgrades', async () => {
  assert.ok((await read('supabase_schema.sql')).toString().endsWith((await read('migrations/001_security_hardening.sql')).toString()));
});

test('application scripts parse and legacy application no longer contains credentials', async () => {
  for (const path of ['index.html','404.html','ks_live_deploy/index.html','ks_live_deploy/404.html']) {
    const html=(await read(path)).toString();
    for (const match of html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g)) new Script(match[1],{filename:path});
    assert.doesNotMatch(html,/generateKitTokenForTest|ZEGO_SERVER_SECRET|ZEGO_APP_SIGN|\bZSIGN\b|\bA\./);
  }
});

test('manifest icons have real PNG encoding and matching dimensions', async () => {
  const manifest=JSON.parse((await read('manifest.json')).toString());
  for (const icon of manifest.icons) {
    const bytes=await read(icon.src.replace('./',''));
    assert.equal(bytes.subarray(0,8).toString('hex'),'89504e470d0a1a0a');
    assert.equal(`${bytes.readUInt32BE(16)}x${bytes.readUInt32BE(20)}`,icon.sizes);
  }
});
