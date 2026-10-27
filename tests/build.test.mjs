import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { access, readFile } from "node:fs/promises";
test("deployment build includes public configuration and excludes private source", async () => {
  const env = {
    ...process.env,
    PUBLIC_SUPABASE_URL: "https://project.example.test",
    PUBLIC_SUPABASE_ANON_KEY: "sb_publishable_unit_fixture",
  };
  const result = spawnSync(process.execPath, ["scripts/build.mjs"], {
    env,
    encoding: "utf8",
  });
  assert.equal(result.status, 0, result.stderr);
  for (
    const file of [
      "supabase",
      "migrations",
      "tests",
      "node_modules",
      ".env",
      "package-lock.json",
    ]
  ) await assert.rejects(access("dist/" + file));
  const html = await readFile("dist/index.html", "utf8");
  assert.match(html, /app\/config.js/);
  assert.doesNotMatch(html, /eyJhbGci|pk_live_|sk_live_/);
  const config = await readFile("dist/app/config.js", "utf8");
  assert.match(config, /sb_publishable_unit_fixture/);
  const bad =
    Buffer.from(JSON.stringify({ alg: "HS256" })).toString("base64url") + "." +
    Buffer.from(JSON.stringify({ role: "service_role" })).toString(
      "base64url",
    ) + ".unit_fixture";
  const rejected = spawnSync(process.execPath, ["scripts/build.mjs"], {
    env: { ...env, PUBLIC_SUPABASE_ANON_KEY: bad },
    encoding: "utf8",
  });
  assert.notEqual(rejected.status, 0);
  assert.doesNotMatch(
    rejected.stderr,
    new RegExp(bad.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")),
  );
});
