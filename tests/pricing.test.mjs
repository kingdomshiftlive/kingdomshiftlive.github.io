import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { runInNewContext } from "node:vm";
import {
  COIN_PRODUCTS,
  PRO_MONTHLY_CENTS,
} from "../supabase/functions/_shared/platform.mjs";
test("owner-approved coin package totals and prices match the trusted checkout catalog", async () => {
  const html = await readFile("index.html", "utf8");
  const match = html.match(/const COIN_PACKAGES=(\[[\s\S]*?\n\]);/);
  assert.ok(match);
  const packages = runInNewContext(match[1]);
  const expected = Object.fromEntries(
    packages.map(
      (p) => [p.id, {
        amount: Math.round(p.price * 100),
        credits: p.coins + p.bonus,
      }],
    ),
  );
  assert.deepEqual(expected, COIN_PRODUCTS);
  assert.equal(PRO_MONTHLY_CENTS, 1900);
});
test("gift and shop settlement retain the approved creator splits", async () => {
  const sql = await readFile("migrations/003_billing_streams.sql", "utf8");
  assert.match(sql, /floor\(cost\*0\.20\)/);
  assert.match(sql, /floor\(receipt\.amount_cents\*0\.77\)/);
});
