import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { PGlite } from "@electric-sql/pglite";
const a = "11111111-1111-4111-8111-111111111111",
  b = "22222222-2222-4222-8222-222222222222",
  op = "33333333-3333-4333-8333-333333333333";
test("payment ledger and operational migrations", async (t) => {
  const db = new PGlite();
  try {
    await db.exec(
      `CREATE ROLE anon;CREATE ROLE authenticated;CREATE ROLE service_role BYPASSRLS;CREATE SCHEMA auth;CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;GRANT USAGE ON SCHEMA public,auth TO anon,authenticated,service_role;`,
    );
    await db.exec(
      await readFile(
        new URL("../supabase_schema.sql", import.meta.url),
        "utf8",
      ),
    );
    for (
      const file of [
        "002_customer_platform.sql",
        "003_billing_streams.sql",
        "004_catalog_and_operations.sql",
      ]
    ) {
      const sql = await readFile(
        new URL("../migrations/" + file, import.meta.url),
        "utf8",
      );
      await db.exec(sql);
      await db.exec(sql);
    }
    await db.exec(
      "UPDATE platform_settings SET value='test' WHERE key='payment_environment'",
    );
    await db.query(
      "INSERT INTO profiles(id,username,role) VALUES($1,'alice','creator'),($2,'bob','creator'),($3,'operator','admin')",
      [a, b, op],
    );
    async function as(role, id = "") {
      await db.exec("RESET ROLE");
      await db.query("SELECT set_config('request.jwt.claim.sub',$1,false)", [
        id,
      ]);
      await db.exec("SET ROLE " + role);
    }
    let order;
    await t.test("only verified service receipts grant credits and repeated delivery is idempotent", async () => {
      await as("service_role");
      order = (await db.query(
        "INSERT INTO checkout_orders(user_id,request_key,kind,product_id,amount_cents,credits,stripe_session) VALUES($1,gen_random_uuid(),'coins','coins_500',499,550,'cs_test_fixture') RETURNING id",
        [a],
      )).rows[0].id;
      await assert.rejects(
        db.query(
          "SELECT fulfill_checkout($1,'cs_test_fixture',1,'usd','evt_wrong',null)",
          [order],
        ),
        /mismatch/,
      );
      await assert.rejects(
        db.query(
          "SELECT fulfill_checkout($1,'cs_test_fixture',499,null,'evt_no_currency',null)",
          [order],
        ),
        /mismatch/,
      );
      await db.query(
        "SELECT fulfill_checkout($1,'cs_test_fixture',499,'usd','evt_paid',null)",
        [order],
      );
      await db.query(
        "SELECT fulfill_checkout($1,'cs_test_fixture',499,'usd','evt_paid',null)",
        [order],
      );
      assert.equal(
        (await db.query("SELECT coins FROM profiles WHERE id=$1", [a])).rows[0]
          .coins,
        550,
      );
      assert.equal(
        (await db.query("SELECT count(*) AS n FROM coin_ledger")).rows[0].n,
        1,
      );
      await as("authenticated", a);
      await assert.rejects(
        db.query(
          "SELECT fulfill_checkout($1,'cs_test_fixture',499,'usd','evt_fake',null)",
          [order],
        ),
        /permission denied/,
      );
      await assert.rejects(
        db.query(
          "INSERT INTO coin_ledger(user_id,delta,source) VALUES($1,1000,'forged')",
          [a],
        ),
        /permission denied/,
      );
    });
    await t.test("expired or failed checkout cannot credit an account or block settlement forever", async () => {
      await as("service_role");
      const canceled = (await db.query(
        "INSERT INTO checkout_orders(user_id,request_key,kind,product_id,amount_cents,credits,stripe_session) VALUES($1,gen_random_uuid(),'coins','coins_100',99,100,'cs_test_canceled') RETURNING id",
        [a],
      )).rows[0].id;
      await db.query(
        "SELECT cancel_checkout($1,'cs_test_canceled','evt_expired')",
        [canceled],
      );
      await db.query(
        "SELECT cancel_checkout($1,'cs_test_canceled','evt_expired')",
        [canceled],
      );
      assert.equal(
        (await db.query("SELECT status FROM checkout_orders WHERE id=$1", [
          canceled,
        ])).rows[0].status,
        "canceled",
      );
      await assert.rejects(
        db.query(
          "SELECT fulfill_checkout($1,'cs_test_canceled',99,'usd','evt_invalid_credit',null)",
          [canceled],
        ),
        /not pending/,
      );
      assert.equal(
        (await db.query("SELECT coins FROM profiles WHERE id=$1", [a])).rows[0]
          .coins,
        550,
      );
      await as("authenticated", a);
      await assert.rejects(
        db.query("SELECT cancel_checkout($1,'cs_test_canceled','evt_forged')", [
          canceled,
        ]),
        /permission denied/,
      );
    });
    await t.test("gifts charge the server price once and cannot overdraw a balance", async () => {
      await as("service_role");
      const stream =
        (await db.query("SELECT start_live_stream($1,'Worship') AS id", [b]))
          .rows[0].id;
      await db.query("UPDATE live_streams SET status='live' WHERE id=$1", [
        stream,
      ]);
      await as("authenticated", a);
      const key = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
      assert.equal(
        (await db.query("SELECT send_live_gift($1,'Rose',$2) AS coins", [
          stream,
          key,
        ])).rows[0].coins,
        545,
      );
      assert.equal(
        (await db.query("SELECT send_live_gift($1,'Rose',$2) AS coins", [
          stream,
          key,
        ])).rows[0].coins,
        545,
      );
      await assert.rejects(
        db.query("SELECT send_live_gift($1,'GLORY',gen_random_uuid())", [
          stream,
        ]),
        /Insufficient/,
      );
      await assert.rejects(
        db.query("SELECT send_live_gift($1,'Diamond',$2)", [stream, key]),
        /already used/,
      );
      await as("service_role");
      assert.equal(
        Number(
          (await db.query(
            "SELECT balance FROM creator_wallets WHERE creator_id=$1",
            [b],
          )).rows[0].balance,
        ),
        0.01,
      );
    });
    let item;
    await t.test("digital products require moderation and paid purchases are private", async () => {
      await as("authenticated", b);
      item = (await db.query(
        "SELECT save_shop_item(null,'Prayer Journal','A digital journal',19,'eBook',$1) AS id",
        [b + "/journal.pdf"],
      )).rows[0].id;
      await assert.rejects(
        db.query("SELECT moderate_shop_item($1,'published','reviewed')", [
          item,
        ]),
        /Administrator/,
      );
      await as("authenticated", op);
      await db.query(
        "SELECT moderate_shop_item($1,'published','Reviewed PDF')",
        [item],
      );
      await as("service_role");
      const purchase = (await db.query(
        "INSERT INTO checkout_orders(user_id,request_key,kind,product_id,amount_cents,item_id,seller_id,stripe_session) VALUES($1,gen_random_uuid(),'shop',$2,1900,$3,$4,'cs_test_shop') RETURNING id",
        [a, item, item, b],
      )).rows[0].id;
      await db.query(
        "SELECT fulfill_checkout($1,'cs_test_shop',1900,'usd','evt_shop',null)",
        [purchase],
      );
      await as("authenticated", a);
      assert.equal((await db.query("SELECT * FROM purchases")).rows.length, 1);
      await as("authenticated", b);
      assert.equal((await db.query("SELECT * FROM purchases")).rows.length, 0);
    });
    await t.test("withdrawals enforce the current follower gate and reserve funds once", async () => {
      await db.exec("RESET ROLE");
      await db.query(
        "UPDATE creator_wallets SET balance=75,locked=false WHERE creator_id=$1",
        [b],
      );
      await db.query("UPDATE profiles SET followers=4999 WHERE id=$1", [b]);
      await as("authenticated", b);
      await assert.rejects(
        db.query("SELECT request_withdrawal()"),
        /eligibility/,
      );
      await db.exec("RESET ROLE");
      await db.query("UPDATE profiles SET followers=5000 WHERE id=$1", [b]);
      await as("authenticated", b);
      assert.ok(
        (await db.query("SELECT request_withdrawal() AS id")).rows[0].id,
      );
      assert.equal(
        Number(
          (await db.query("SELECT balance FROM creator_wallets")).rows[0]
            .balance,
        ),
        0,
      );
      await assert.rejects(
        db.query("SELECT request_withdrawal()"),
        /eligibility/,
      );
    });
    await t.test("Pro entitlements follow verified subscription status and safety reports are bounded", async () => {
      await as("authenticated", a);
      await assert.rejects(
        db.query("SELECT creator_analytics()"),
        /active Creator Pro/,
      );
      await assert.rejects(
        db.query(
          "SELECT submit_safety_report(null,'Detailed safety concern','other')",
        ),
        /valid content URL/,
      );
      await db.query(
        "SELECT submit_safety_report('https://example.test/post','Detailed safety concern','child_safety')",
      );
      await assert.rejects(
        db.query("INSERT INTO reports(reporter_id,type) VALUES($1,'other')", [
          a,
        ]),
        /permission denied/,
      );
      await as("service_role");
      const pro = (await db.query(
        "INSERT INTO checkout_orders(user_id,request_key,kind,product_id,amount_cents,stripe_session) VALUES($1,gen_random_uuid(),'pro','creator_pro',1900,'cs_test_pro') RETURNING id",
        [a],
      )).rows[0].id;
      await db.query(
        "SELECT fulfill_checkout($1,'cs_test_pro',1900,'usd','evt_test_pro','sub_test_pro')",
        [pro],
      );
      await as("authenticated", a);
      assert.equal(
        (await db.query("SELECT get_my_account() AS data")).rows[0].data.is_pro,
        true,
      );
      assert.equal(
        (await db.query("SELECT creator_analytics() AS data")).rows[0].data
          .posts,
        0,
      );
      await as("service_role");
      await db.query("SELECT sync_subscription('sub_test_pro','canceled')");
      await as("authenticated", a);
      await assert.rejects(
        db.query("SELECT creator_analytics()"),
        /active Creator Pro/,
      );
    });
    await t.test("refund incidents lock access, and erasure requires settlement", async () => {
      await as("service_role");
      await db.query(
        "UPDATE checkout_orders SET payment_intent='pi_test_fixture' WHERE id=$1",
        [order],
      );
      await db.query(
        "SELECT flag_payment_incident('pi_test_fixture','evt_refund','charge.refunded')",
      );
      assert.equal(
        (await db.query("SELECT status FROM checkout_orders WHERE id=$1", [
          order,
        ])).rows[0].status,
        "review",
      );
      assert.equal(
        (await db.query("SELECT suspended FROM profiles WHERE id=$1", [a]))
          .rows[0].suspended,
        true,
      );
      await as("authenticated", b);
      const request =
        (await db.query("SELECT request_account_deletion() AS id")).rows[0].id;
      await as("service_role");
      await assert.rejects(
        db.query("SELECT prepare_account_erasure($1,$2)", [b, request]),
        /Settle/,
      );
      await as("authenticated", op);
      const operatorRequest =
        (await db.query("SELECT request_account_deletion() AS id")).rows[0].id;
      await as("service_role");
      await db.query("SELECT erase_account_data($1,$2)", [op, operatorRequest]);
      assert.equal(
        (await db.query("SELECT role FROM profiles WHERE id=$1", [op])).rows[0]
          .role,
        "deleted",
      );
      await as("authenticated", a);
      await assert.rejects(
        db.query("SELECT erase_account_data($1,$2)", [b, request]),
        /permission denied/,
      );
    });
  } finally {
    await db.close();
  }
});
