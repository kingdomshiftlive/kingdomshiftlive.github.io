import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { PGlite } from '@electric-sql/pglite';

const alice = '11111111-1111-4111-8111-111111111111';
const bob = '22222222-2222-4222-8222-222222222222';
const charlie = '33333333-3333-4333-8333-333333333333';

test('database access controls on fresh and upgraded installations', async t => {
  const db = new PGlite();
  try {
    await db.exec(`CREATE ROLE anon; CREATE ROLE authenticated;
      CREATE SCHEMA auth;
      CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS
        $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
      GRANT USAGE ON SCHEMA public,auth TO anon,authenticated;
      GRANT EXECUTE ON FUNCTION auth.uid() TO anon,authenticated;`);
    await db.exec(await readFile(new URL('../supabase_schema.sql', import.meta.url), 'utf8'));
    const migration = await readFile(new URL('../migrations/001_security_hardening.sql', import.meta.url), 'utf8');
    await db.exec(migration);
    // Simulate legacy permissive grants and an unknown policy before upgrading.
    await db.exec(`GRANT ALL ON ALL TABLES IN SCHEMA public TO PUBLIC,anon,authenticated;
      ALTER TABLE public.profiles DISABLE ROW LEVEL SECURITY;
      GRANT UPDATE (coins), SELECT (email) ON public.profiles TO anon,authenticated;
      CREATE POLICY legacy_open_updates ON public.live_streams FOR UPDATE USING (true);
      INSERT INTO public.profiles(id,username,email) VALUES
        ('${alice}','alice','alice@example.test'),('${bob}','bob','bob@example.test');
      INSERT INTO public.videos(creator_id,title) VALUES ('${alice}','Public video');
      INSERT INTO public.shop_items(creator_id,name,price,type,file_url)
        VALUES ('${alice}','Book',10,'eBook','https://example.test/paid');
      INSERT INTO public.live_streams(id,creator_id,title) VALUES ('stream', '${alice}', 'Live');`);
    await db.exec(migration);
    async function as(role, id='') {
      await db.exec('RESET ROLE');
      await db.query("SELECT set_config('request.jwt.claim.sub',$1,false)",[id]);
      await db.exec(`SET ROLE ${role}`);
    }
    await t.test('public fields are readable but email and settings are private', async () => {
      await as('anon');
      assert.equal((await db.query('SELECT id,username FROM public.profiles')).rows.length,2);
      await assert.rejects(db.query('SELECT email FROM public.profiles'),/permission denied/);
      await assert.rejects(db.query('SELECT privacy_settings FROM public.profiles'),/permission denied/);
      await assert.rejects(db.query('SELECT file_url FROM public.shop_items'),/permission denied/);
      await assert.rejects(db.query('SELECT * FROM public.creator_wallets'),/permission denied/);
    });
    await t.test('owners can edit their display name but cannot mint money or entitlements', async () => {
      await as('authenticated',alice);
      await db.query("UPDATE public.profiles SET display_name='Alice' WHERE id=$1",[alice]);
      for (const [column,value] of [['coins','100000'],['followers','5000'],['role',"'admin'"],['verified','true'],['is_pro','true']]) {
        await assert.rejects(db.query(`UPDATE public.profiles SET ${column}=${value} WHERE id=$1`,[alice]),/permission denied/);
      }
      await assert.rejects(db.query('UPDATE public.creator_wallets SET balance=999999'),/permission denied/);
      await assert.rejects(db.query("INSERT INTO public.withdrawal_requests(creator_id,amount,method) VALUES ($1,50,'stripe')",[alice]),/permission denied/);
      assert.equal((await db.query('SELECT * FROM public.creator_wallets')).rows.length,1);
      const changed=await db.query("UPDATE public.profiles SET display_name='Imposter' WHERE id=$1 RETURNING id",[bob]);
      assert.equal(changed.rows.length,0);
    });
    await t.test('profile creation uses safe defaults and creates an owner wallet', async () => {
      await as('authenticated',charlie);
      await db.query("INSERT INTO public.profiles(id,username,display_name) VALUES ($1,'charlie','Charlie')",[charlie]);
      const profile=(await db.query('SELECT coins,followers,role,is_pro FROM public.profiles WHERE id=$1',[charlie])).rows[0];
      assert.deepEqual(profile,{coins:0,followers:0,role:'creator',is_pro:false});
      assert.equal((await db.query('SELECT * FROM public.creator_wallets')).rows.length,1);
      await assert.rejects(db.query("INSERT INTO public.profiles(id,username,coins) VALUES ($1,'fake',900)",[bob]),/permission denied/);
    });
    await t.test('private account hides profile, videos, shop and streams from other viewers', async () => {
      await as('authenticated',alice);
      await db.query('UPDATE public.profiles SET privacy_settings=$1 WHERE id=$2',[JSON.stringify({privateAccount:true}),alice]);
      const settings=(await db.query('SELECT public.get_my_settings() AS settings')).rows[0].settings;
      assert.equal(settings.privacy_settings.privateAccount,true);
      assert.equal((await db.query('SELECT id FROM public.videos')).rows.length,1);
      for (const role of ['anon','authenticated']) {
        await as(role,role==='authenticated'?bob:'');
        assert.equal((await db.query('SELECT id FROM public.profiles WHERE id=$1',[alice])).rows.length,0);
        for (const table of ['videos','shop_items','live_streams']) assert.equal((await db.query(`SELECT id FROM public.${table}`)).rows.length,0);
      }
      await as('authenticated',bob);
      assert.equal((await db.query('SELECT public.get_my_settings() AS settings')).rows[0].settings.privacy_settings.privateAccount,undefined);
    });
    await t.test('neither visitors nor owners can modify streams through the public API', async () => {
      for (const [role,id] of [['anon',''],['authenticated',alice],['authenticated',bob]]) {
        await as(role,id);
        await assert.rejects(db.query("UPDATE public.live_streams SET title='Hijacked' WHERE id='stream'"),/permission denied/);
      }
    });
    await t.test('reports require the actual reporter, details, and a content URL', async () => {
      await as('authenticated',alice);
      const insert=`INSERT INTO public.reports(reporter_id,reported_id,type,status,priority,content_url,details)
        VALUES ($1,null,'other','pending','normal','https://example.test/post','Please review this content')`;
      await db.query(insert,[alice]);
      await assert.rejects(db.query(insert,[bob]),/row-level security/);
      await assert.rejects(db.query("INSERT INTO public.reports(reporter_id,type) VALUES ($1,'other')",[alice]),/row-level security/);
      await assert.rejects(db.query('SELECT * FROM public.reports'),/permission denied/);
      await as('anon');
      await assert.rejects(db.query(insert,[alice]),/permission denied/);
    });
  } finally { await db.close(); }
});
