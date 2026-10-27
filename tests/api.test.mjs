import { test } from "node:test";
import assert from "node:assert/strict";
import { createDecipheriv } from "node:crypto";
import Stripe from "stripe";
import { createPlatformHandler } from "../supabase/functions/_shared/platform.mjs";
import { issueZegoToken } from "../supabase/functions/_shared/zego-token.mjs";
const a = "11111111-1111-4111-8111-111111111111",
  b = "22222222-2222-4222-8222-222222222222",
  key = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
function fixture(overrides = {}) {
  const rows = {
    profiles: [{ id: a, role: "creator", suspended: false }, {
      id: b,
      role: "creator",
      suspended: false,
    }],
    checkout_orders: [],
    live_streams: [{
      id: "ks_" + key,
      creator_id: b,
      status: "live",
      lease_expires_at: new Date(Date.now() + 60000).toISOString(),
    }],
  };
  const calls = [];
  const admin = {
    auth: {
      getUser: async (token) => ({
        data: token === "valid" ? { user: { id: a } } : null,
        error: token === "valid" ? null : { message: "bad token" },
      }),
    },
    rpc: async (name, args) => {
      calls.push({ rpc: name, args });
      return {
        data: name === "platform_health"
          ? { schema_version: 4 }
          : name === "billing_environment"
          ? "test"
          : null,
        error: null,
      };
    },
    from: (table) => {
      let filters = [], operation = "select", record, single = false;
      const q = {
        select: () => q,
        eq: (field, value) => {
          filters.push((row) => row[field] === value);
          return q;
        },
        not: () => q,
        limit: () => q,
        single: () => {
          single = true;
          return q;
        },
        maybeSingle: () => {
          single = true;
          return q;
        },
        insert: (value) => {
          operation = "insert";
          record = value;
          return q;
        },
        update: (value) => {
          operation = "update";
          record = value;
          return q;
        },
        then: (resolve, reject) => {
          rows[table] ||= [];
          let selected = rows[table].filter((row) =>
            filters.every((filter) => filter(row))
          );
          if (operation === "insert") {
            if (table === "checkout_orders") {
              record = { status: "pending", ...record };
            }
            rows[table].push(record);
            selected = [record];
          }
          if (operation === "update") {
            selected.forEach((row) => Object.assign(row, record));
          }
          return Promise.resolve({
            data: single ? selected[0] || null : selected,
            error: null,
          }).then(resolve, reject);
        },
      };
      return q;
    },
  };
  const stripe = {
    checkout: {
      sessions: {
        create: async (payload, options) => {
          calls.push({ checkout: payload, options });
          return {
            id: "cs_test_fixture",
            url: "https://checkout.stripe.com/c/pay/test_fixture",
          };
        },
      },
    },
    subscriptions: { retrieve: async (id) => ({ id, status: "active" }) },
  };
  const settings = {
    siteURL: "https://kingdomshiftlive.github.io/",
    billingMode: "test",
    streamingEnabled: true,
    zegoAppId: 1234,
    ...overrides,
  };
  const handler = createPlatformHandler({
    admin,
    stripe,
    issueToken: (input) => {
      calls.push({ token: input });
      return "04test_token";
    },
    settings,
    verifyWebhook: overrides.verifyWebhook || (() => {
      throw Error("bad signature");
    }),
  });
  const request = (path, body, options = {}) =>
    handler(
      new Request("https://project.example.test/functions/v1/platform" + path, {
        method: body === undefined ? "GET" : "POST",
        headers: {
          authorization: "Bearer valid",
          origin: settings.siteURL.slice(0, -1),
          "content-type": "application/json",
          ...options.headers,
        },
        ...(body === undefined
          ? {}
          : { body: typeof body === "string" ? body : JSON.stringify(body) }),
        ...options,
      }),
    );
  return { handler, request, rows, calls, admin, settings };
}
test("API rejects foreign origins and unauthenticated writes", async () => {
  const f = fixture();
  assert.equal(
    (await f.request("/health", undefined, {
      headers: { origin: "https://evil.example" },
    })).status,
    403,
  );
  assert.equal(
    (await f.request("/checkout", {}, {
      headers: { authorization: "Bearer forged" },
    })).status,
    401,
  );
  assert.equal(f.rows.checkout_orders.length, 0);
});
test("checkout uses trusted catalog pricing, binds ownership, and prevents request-key reuse", async () => {
  const f = fixture();
  const response = await f.request("/checkout", {
    kind: "coins",
    product_id: "coins_500",
    request_key: key,
    price: 1,
    credits: 999999,
    user_id: b,
  });
  assert.equal(response.status, 200);
  const order = f.rows.checkout_orders[0];
  assert.equal(order.user_id, a);
  assert.equal(order.amount_cents, 499);
  assert.equal(order.credits, 550);
  assert.equal(
    f.calls.find((c) => c.checkout).checkout.line_items[0].price_data
      .unit_amount,
    499,
  );
  assert.equal(
    (await f.request("/checkout", {
      kind: "coins",
      product_id: "coins_100",
      request_key: key,
    })).status,
    409,
  );
});
test("disabled and unapproved live billing never create checkout sessions", async () => {
  for (const billingMode of ["disabled", "live"]) {
    const f = fixture({ billingMode });
    assert.equal(
      (await f.request("/checkout", {
        kind: "coins",
        product_id: "coins_500",
        request_key: key,
      })).status,
      503,
    );
    assert.equal(f.calls.filter((c) => c.checkout).length, 0);
  }
});
test("webhook verifies real Stripe signatures and rejects mismatched modes", async () => {
  const sdk = new Stripe("sk_test_unit_fixture");
  const secret = "whsec_unit_fixture";
  const event = {
    id: "evt_unit_fixture",
    type: "checkout.session.completed",
    livemode: false,
    data: {
      object: {
        id: "cs_test_fixture",
        payment_status: "paid",
        amount_total: 499,
        currency: "usd",
        metadata: { order_id: key },
        subscription: null,
      },
    },
  };
  const payload = JSON.stringify(event);
  const verifyWebhook = (raw, signature) =>
    sdk.webhooks.constructEvent(raw, signature, secret);
  const f = fixture({ verifyWebhook });
  assert.equal(
    (await f.request("/webhook", payload, {
      headers: { "stripe-signature": "invalid" },
    })).status,
    400,
  );
  const signature = sdk.webhooks.generateTestHeaderString({ payload, secret });
  assert.equal(
    (await f.request("/webhook", payload, {
      headers: { "stripe-signature": signature },
    })).status,
    200,
  );
  assert.equal(
    f.calls.find((c) => c.rpc === "fulfill_checkout").args.amount,
    499,
  );
  const livePayload = JSON.stringify({ ...event, livemode: true });
  const liveSignature = sdk.webhooks.generateTestHeaderString({
    payload: livePayload,
    secret,
  });
  assert.equal(
    (await f.request("/webhook", livePayload, {
      headers: { "stripe-signature": liveSignature },
    })).status,
    400,
  );
});
test("audience token cannot publish or manage another creator stream", async () => {
  const f = fixture();
  const result = await f.request("/streams/ks_" + key + "/token", {});
  assert.equal(result.status, 200);
  assert.equal((await result.json()).host, false);
  assert.equal(f.calls.find((c) => c.token).token.host, false);
  assert.equal(
    (await f.request("/streams/ks_" + key + "/end", {})).status,
    403,
  );
});
test("oversized bodies and unauthorized erasure requests are rejected", async () => {
  const f = fixture();
  assert.equal(
    (await f.request("/checkout", { blob: "x".repeat(140000) })).status,
    413,
  );
  assert.equal(
    (await f.request("/admin/deletions/" + key + "/process", {})).status,
    403,
  );
  assert.ok(!f.calls.some((c) => c.rpc === "erase_account_data"));
});
test("Token04 is room-bound, permission-bound, short-lived, and nondeterministic", () => {
  const secret = "unit-test-secret-32-bytes-long!!!".slice(0, 32);
  assert.equal(Buffer.byteLength(secret), 32);
  const input = {
    appId: 1234,
    secret,
    userId: a,
    roomId: "ks_" + key,
    host: false,
    now: 1000,
  };
  const token = issueZegoToken(input);
  assert.notEqual(token, issueZegoToken(input));
  const bytes = Buffer.from(token.slice(2), "base64");
  assert.equal(Number(bytes.readBigInt64BE()), 1600);
  const ivSize = bytes.readUInt16BE(8), iv = bytes.subarray(10, 10 + ivSize);
  const size = bytes.readUInt16BE(10 + ivSize);
  const encrypted = bytes.subarray(12 + ivSize, 12 + ivSize + size);
  const decipher = createDecipheriv("aes-256-cbc", Buffer.from(secret), iv);
  const claims = JSON.parse(
    Buffer.concat([decipher.update(encrypted), decipher.final()]).toString(),
  );
  assert.equal(claims.user_id, a);
  const payload = JSON.parse(claims.payload);
  assert.equal(payload.room_id, "ks_" + key);
  assert.equal(payload.privilege[2], 0);
});

test("signed expired checkout events close pending receipts without granting value", async () => {
  const sdk = new Stripe("sk_test_unit_fixture"), secret = "whsec_unit_fixture";
  const event = {
    id: "evt_expired_fixture",
    type: "checkout.session.expired",
    livemode: false,
    data: { object: { id: "cs_test_expired", metadata: { order_id: key } } },
  };
  const payload = JSON.stringify(event),
    signature = sdk.webhooks.generateTestHeaderString({ payload, secret });
  const f = fixture({
    verifyWebhook: (raw, header) =>
      sdk.webhooks.constructEvent(raw, header, secret),
  });
  assert.equal(
    (await f.request("/webhook", payload, {
      headers: { "stripe-signature": signature },
    })).status,
    200,
  );
  assert.ok(f.calls.some((c) => c.rpc === "cancel_checkout"));
  assert.ok(!f.calls.some((c) => c.rpc === "fulfill_checkout"));
});
