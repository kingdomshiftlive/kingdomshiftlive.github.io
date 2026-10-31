import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { PGlite } from "@electric-sql/pglite";
const a = "11111111-1111-4111-8111-111111111111",
  b = "22222222-2222-4222-8222-222222222222",
  op = "33333333-3333-4333-8333-333333333333";
test("blocking revokes relationships and access; moderation requires evidence", async () => {
  const db = new PGlite();
  try {
    await db.exec(
      `CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role BYPASSRLS; CREATE SCHEMA auth; CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$; GRANT USAGE ON SCHEMA public,auth TO anon,authenticated;`,
    );
    for (
      const file of [
        "supabase_schema.sql",
        "migrations/002_customer_platform.sql",
        "migrations/003_billing_streams.sql",
        "migrations/004_catalog_and_operations.sql",
        "migrations/005_community_safety.sql",
        "migrations/005_community_safety.sql",
      ]
    ) await db.exec(await readFile(file, "utf8"));
    await db.query(
      "INSERT INTO profiles(id,username,role) VALUES($1,'alice','creator'),($2,'bob','creator'),($3,'op','admin')",
      [a, b, op],
    );
    const video = (await db.query(
      "INSERT INTO videos(creator_id,title,status,file_path) VALUES($1,'Hello','published',$2) RETURNING id",
      [a, a + "/clip.mp4"],
    )).rows[0].id;
    async function as(id) {
      await db.exec("RESET ROLE");
      await db.query("SELECT set_config('request.jwt.claim.sub',$1,false)", [
        id,
      ]);
      await db.exec("SET ROLE authenticated");
    }
    await as(a);
    await db.query("SELECT set_follow($1,true)", [b]);
    await as(b);
    await db.query("SELECT set_follow($1,true)", [a]);
    assert.equal((await db.query("SELECT id FROM videos")).rows.length, 1);
    await as(a);
    await db.query("SELECT set_user_block($1,true)", [b]);
    assert.equal(
      (await db.query("SELECT followers,following FROM profiles WHERE id=$1", [
        a,
      ])).rows[0].followers,
      0,
    );
    await as(b);
    assert.equal((await db.query("SELECT id FROM videos")).rows.length, 0);
    assert.equal(
      (await db.query("SELECT can_view_media($1) AS ok", [a + "/clip.mp4"]))
        .rows[0].ok,
      false,
    );
    for (
      const [sql, args] of [
        ["SELECT set_follow($1,true)", [a]],
        ["SELECT send_message($1,'Hello')", [a]],
        ["SELECT add_comment($1,'Hello')", [video]],
        ["SELECT set_video_like($1,true)", [video]],
      ]
    ) await assert.rejects(db.query(sql, args), /unavailable|cannot be sent/);
    await as(a);
    await db.query("SELECT set_user_block($1,false)", [b]);
    await as(b);
    assert.equal((await db.query("SELECT id FROM videos")).rows.length, 1);
    assert.equal(
      (await db.query("SELECT followers FROM profiles WHERE id=$1", [a]))
        .rows[0].followers,
      0,
    );
    await assert.rejects(
      db.query("SELECT set_user_block($1,NULL)", [a]),
      /Invalid block/,
    );
    await assert.rejects(
      db.query("SELECT set_follow($1,NULL)", [a]),
      /decision/,
    );
    await db.exec("RESET ROLE");
    await db.query(
      "INSERT INTO reports(reporter_id,type,status,priority,created_at) SELECT $1,'other','pending','normal',now()-interval '1 day' FROM generate_series(1,51)",
      [b],
    );
    await as(b);
    const safety = (await db.query(
      "SELECT submit_safety_report('https://example.test/post','Detailed safety concern','child_safety') AS id",
    )).rows[0].id;
    await as(op);
    const queue =
      (await db.query("SELECT admin_overview() AS data")).rows[0].data.reports;
    assert.equal(queue.length, 50);
    assert.equal(queue[0].id, safety);
    assert.equal(queue[0].priority, "urgent");
    await assert.rejects(
      db.query("SELECT moderate_content($1,'removed',NULL)", [video]),
      /review note/,
    );
    await assert.rejects(
      db.query("SELECT moderate_content($1,NULL,'Reviewed')", [video]),
      /review note/,
    );
    const report =
      (await db.query("SELECT gen_random_uuid() AS id")).rows[0].id;
    await assert.rejects(
      db.query("SELECT resolve_report($1,'resolved',NULL)", [report]),
      /review note/,
    );
    await db.query(
      "SELECT moderate_content($1,'removed','Reviewed evidence')",
      [video],
    );
  } finally {
    await db.close();
  }
});
