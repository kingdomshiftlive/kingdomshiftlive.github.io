import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { PGlite } from "@electric-sql/pglite";
const a = "11111111-1111-4111-8111-111111111111",
  b = "22222222-2222-4222-8222-222222222222",
  admin = "33333333-3333-4333-8333-333333333333";
test("real customer persistence, moderation, and authorization", async (t) => {
  const db = new PGlite();
  try {
    await db.exec(
      `CREATE ROLE anon;CREATE ROLE authenticated;CREATE SCHEMA auth;CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;GRANT USAGE ON SCHEMA public,auth TO anon,authenticated;`,
    );
    await db.exec(
      await readFile(
        new URL("../supabase_schema.sql", import.meta.url),
        "utf8",
      ),
    );
    const sql = await readFile(
      new URL("../migrations/002_customer_platform.sql", import.meta.url),
      "utf8",
    );
    await db.exec(sql);
    await db.exec(sql);
    await db.query(
      `INSERT INTO profiles(id,username,role) VALUES ($1,'alice','creator'),($2,'bob','creator'),($3,'admin','admin')`,
      [a, b, admin],
    );
    async function as(id) {
      await db.exec("RESET ROLE");
      await db.query("SELECT set_config('request.jwt.claim.sub',$1,false)", [
        id,
      ]);
      await db.exec("SET ROLE authenticated");
    }
    let content;
    await t.test("creators submit owned content; only admins can publish", async () => {
      await as(a);
      content = (await db.query(
        "SELECT save_content(null,'A teaching','An encouraging message','Faith',null) AS id",
      )).rows[0].id;
      assert.equal(
        (await db.query("SELECT status FROM videos WHERE id=$1", [content]))
          .rows[0].status,
        "pending",
      );
      await assert.rejects(
        db.query("SELECT save_content(null,'bad','bad','Faith',$1)", [
          b + "/foreign.mp4",
        ]),
        /Invalid content/,
      );
      await assert.rejects(
        db.query("SELECT moderate_content($1,'published','Looks good')", [
          content,
        ]),
        /Administrator/,
      );
      await as(b);
      assert.equal((await db.query("SELECT id FROM videos")).rows.length, 0);
      await as(admin);
      await db.query(
        "SELECT moderate_content($1,'published','Reviewed teaching')",
        [content],
      );
      assert.equal(
        (await db.query("SELECT admin_overview() AS result")).rows[0].result
          .published,
        1,
      );
    });
    await t.test("likes, saves, comments and messages persist without direct-write privileges", async () => {
      await as(b);
      await db.query("SELECT set_video_like($1,true)", [content]);
      await db.query("SELECT set_video_like($1,true)", [content]);
      assert.equal(
        (await db.query("SELECT likes FROM videos WHERE id=$1", [content]))
          .rows[0].likes,
        1,
      );
      await db.query("SELECT set_video_saved($1,true)", [content]);
      assert.equal(
        (await db.query("SELECT * FROM video_saves")).rows.length,
        1,
      );
      await db.query("SELECT add_comment($1,'Thoughtful message')", [content]);
      await db.query("SELECT send_message($1,'Hello Alice')", [a]);
      await assert.rejects(
        db.query(
          "INSERT INTO direct_messages(sender_id,recipient_id,body) VALUES ($1,$2,'forged')",
          [a, b],
        ),
        /permission denied/,
      );
      await as(a);
      assert.equal(
        (await db.query("SELECT body FROM direct_messages")).rows[0].body,
        "Hello Alice",
      );
      assert.ok(
        (await db.query("SELECT * FROM notifications")).rows.length >= 2,
      );
      await db.query("SELECT set_user_block($1,true)", [b]);
      await as(b);
      await assert.rejects(
        db.query("SELECT send_message($1,'Blocked')", [a]),
        /cannot be sent/,
      );
      await assert.rejects(
        db.query("SELECT add_comment($1,'Blocked')", [content]),
        /unavailable/,
      );
      await as(a);
      await db.query("SELECT set_user_block($1,false)", [b]);
      await as(admin);
      assert.equal(
        (await db.query("SELECT * FROM direct_messages")).rows.length,
        0,
      );
    });
    await t.test("private content requires an accepted follow request", async () => {
      await as(a);
      await db.query("UPDATE profiles SET privacy_settings=$1 WHERE id=$2", [
        JSON.stringify({ privateAccount: true }),
        a,
      ]);
      await as(b);
      assert.equal((await db.query("SELECT id FROM videos")).rows.length, 0);
      assert.equal(
        (await db.query("SELECT set_follow($1,true) AS result", [a])).rows[0]
          .result,
        "pending",
      );
      await db.query("SELECT review_follow($1,true)", [b]);
      assert.equal((await db.query("SELECT id FROM videos")).rows.length, 0);
      await as(a);
      assert.equal(
        (await db.query("SELECT * FROM get_follow_requests()")).rows.length,
        1,
      );
      await db.query("SELECT review_follow($1,true)", [b]);
      await as(b);
      assert.equal((await db.query("SELECT id FROM videos")).rows.length, 1);
      assert.equal(
        (await db.query("SELECT followers FROM profiles WHERE id=$1", [a]))
          .rows[0].followers,
        1,
      );
    });
    await t.test("moderation cannot be spoofed and deletion requests deactivate accounts", async () => {
      await as(b);
      await assert.rejects(
        db.query("SELECT admin_overview()"),
        /Administrator/,
      );
      await assert.rejects(
        db.query("UPDATE profiles SET role='admin' WHERE id=$1", [b]),
        /permission denied/,
      );
      await as(admin);
      await db.query("SELECT suspend_member($1,true,'Reviewed abuse report')", [
        b,
      ]);
      await as(b);
      await assert.rejects(
        db.query("SELECT send_message($1,'Inactive')", [a]),
        /active account/,
      );
      await as(a);
      const request =
        (await db.query("SELECT request_account_deletion() AS id")).rows[0].id;
      assert.ok(request);
      await assert.rejects(
        db.query("SELECT save_content(null,'Inactive','Message','Faith',null)"),
        /active account/,
      );
      await as(admin);
      const overview =
        (await db.query("SELECT admin_overview() AS data")).rows[0].data;
      assert.equal(overview.deletions.length, 1);
      await db.exec("RESET ROLE");
      assert.equal(
        (await db.query("SELECT count(*) AS total FROM admin_audit_log"))
          .rows[0].total,
        2,
      );
    });
  } finally {
    await db.close();
  }
});
