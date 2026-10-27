import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { PGlite } from "@electric-sql/pglite";
const a = "11111111-1111-4111-8111-111111111111",
  b = "22222222-2222-4222-8222-222222222222";
test("storage policies enforce ownership, private media access and moderation roles", async () => {
  const db = new PGlite();
  try {
    await db.exec(
      `CREATE ROLE anon;CREATE ROLE authenticated;CREATE ROLE service_role BYPASSRLS;CREATE SCHEMA auth;CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;GRANT USAGE ON SCHEMA public,auth TO anon,authenticated,service_role;
 CREATE SCHEMA storage;CREATE TABLE storage.buckets(id text PRIMARY KEY,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);CREATE TABLE storage.objects(id uuid DEFAULT gen_random_uuid(),bucket_id text,name text);ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;GRANT USAGE ON SCHEMA storage TO anon,authenticated;GRANT SELECT,INSERT,DELETE ON storage.objects TO anon,authenticated;CREATE FUNCTION storage.foldername(text) RETURNS text[] LANGUAGE sql IMMUTABLE AS $$SELECT (string_to_array($1,'/'))[1:array_length(string_to_array($1,'/'),1)-1]$$;`,
    );
    await db.exec(await readFile("supabase_schema.sql", "utf8"));
    for (
      const file of [
        "002_customer_platform.sql",
        "003_billing_streams.sql",
        "004_catalog_and_operations.sql",
      ]
    ) await db.exec(await readFile("migrations/" + file, "utf8"));
    const storage = await readFile("supabase/storage.sql", "utf8");
    await db.exec(storage);
    await db.exec(storage);
    await db.query(
      "INSERT INTO profiles(id,username) VALUES($1,'alice'),($2,'bob')",
      [a, b],
    );
    await db.query(
      "INSERT INTO videos(creator_id,title,file_path,status) VALUES($1,'Public',$2,'published')",
      [a, a + "/public.mp4"],
    );
    async function as(role, id = "") {
      await db.exec("RESET ROLE");
      await db.query("SELECT set_config('request.jwt.claim.sub',$1,false)", [
        id,
      ]);
      await db.exec("SET ROLE " + role);
    }
    await as("authenticated", a);
    await db.query(
      "INSERT INTO storage.objects(bucket_id,name) VALUES('videos',$1)",
      [a + "/public.mp4"],
    );
    await assert.rejects(
      db.query(
        "INSERT INTO storage.objects(bucket_id,name) VALUES('videos',$1)",
        [b + "/forged.mp4"],
      ),
      /row-level security/,
    );
    await db.query(
      "INSERT INTO storage.objects(bucket_id,name) VALUES('shop-files',$1)",
      [a + "/resource.pdf"],
    );
    await as("anon");
    assert.equal(
      (await db.query("SELECT * FROM storage.objects")).rows.length,
      1,
    );
    await as("authenticated", b);
    assert.equal(
      (await db.query(
        "SELECT * FROM storage.objects WHERE bucket_id='shop-files'",
      )).rows.length,
      0,
    );
    await assert.rejects(
      db.query("SELECT coins,role FROM profiles"),
      /permission denied/,
    );
    const account =
      (await db.query("SELECT get_my_account() AS data")).rows[0].data;
    assert.equal(account.coins, 0);
    assert.equal(account.role, "creator");
    await as("authenticated", a);
    await db.query("UPDATE profiles SET privacy_settings=$1 WHERE id=$2", [
      JSON.stringify({ privateAccount: true }),
      a,
    ]);
    await as("anon");
    assert.equal(
      (await db.query("SELECT * FROM storage.objects")).rows.length,
      0,
    );
    await as("authenticated", b);
    assert.equal(
      (await db.query("SELECT * FROM storage.objects WHERE bucket_id='videos'"))
        .rows.length,
      0,
    );
    await db.exec("RESET ROLE");
    await db.query("UPDATE profiles SET role='admin' WHERE id=$1", [b]);
    await as("authenticated", b);
    assert.equal(
      (await db.query("SELECT * FROM storage.objects")).rows.length,
      2,
    );
    await db.exec("RESET ROLE");
    await db.query("UPDATE profiles SET suspended=true WHERE id=$1", [a]);
    await as("authenticated", a);
    await assert.rejects(
      db.query(
        "INSERT INTO storage.objects(bucket_id,name) VALUES('videos',$1)",
        [a + "/inactive.mp4"],
      ),
      /row-level security/,
    );
  } finally {
    await db.close();
  }
});
