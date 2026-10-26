"""Browser regressions. All external requests are blocked; writes use an in-memory fake."""
import asyncio
import functools
import http.server
import json
import os
from pathlib import Path
import threading
import unittest
from playwright.async_api import async_playwright

ROOT = Path(__file__).resolve().parents[1]
FAKE_SDK = r"""
window.auditDb={calls:[],error:null};
window.supabase={createClient:()=>({
 auth:{getSession:async()=>({data:{session:window.auditSession||null}}),onAuthStateChange:()=>{},signOut:async()=>({error:null}),resetPasswordForEmail:async()=>({error:null}),updateUser:async()=>({error:null})},
 rpc:async(name,args)=>{window.auditDb.calls.push({rpc:name,args});let data=[];if(name==='get_my_settings')data={privacy_settings:{},notif_settings:{}};if(name==='set_follow')data='accepted';if(name==='save_content'||name==='request_account_deletion')data='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';if(name==='admin_overview')data={profiles:1,published:1,content:[],reports:[],deletions:[]};return {data,error:window.auditDb.error}},
 storage:{from:()=>({createSignedUrl:async()=>({data:{signedUrl:window.auditMediaURL||'/test-media.webm'},error:null}),upload:async()=>({error:null}),remove:async()=>({error:null})})},
 from:(table)=>{
  const q={};let single=false;let inserting=false;
  for(const method of ['select','eq','is','in','order','limit','or','single','maybeSingle','insert','update'])
   q[method]=(...args)=>{if(method==='single'||method==='maybeSingle')single=true;if(method==='insert')inserting=true;window.auditDb.calls.push({table,method,args});return q};
  q.then=(resolve,reject)=>{
   let data=window.auditFixtures?.[table]||[];
   if(table==='videos'&&!window.auditFixtures?.videos)data=[{id:'550e8400-e29b-41d4-a716-446655440000',creator_id:'22222222-2222-4222-8222-222222222222',title:'A teaching',description:'Encouragement',likes:2,status:'published',profiles:{username:'alice',display_name:'Alice'}}];
   if(table==='profiles')data=single?(window.auditMissingProfile&&!inserting?null:{id:window.auditSession?.user.id||'22222222-2222-4222-8222-222222222222',username:'test',display_name:'Test',role:'creator'}):[{id:'22222222-2222-4222-8222-222222222222',username:'test',display_name:window.auditName||'Test'}];
   if(single&&table!=='profiles')data=null;
   return Promise.resolve({data,error:window.auditDb.error}).then(resolve,reject);
  };
  return q;
 }
})};
"""
class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass

class SiteTests(unittest.IsolatedAsyncioTestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(QuietHandler, directory=str(ROOT)))
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.url = f'http://127.0.0.1:{cls.server.server_port}'

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    async def asyncSetUp(self):
        self.pw = await async_playwright().start()
        executable = os.environ.get('CHROMIUM_PATH')
        self.browser = await self.pw.chromium.launch(**({'executable_path':executable} if executable else {}), args=['--no-sandbox'])
        self.context = await self.browser.new_context(service_workers='block')
        self.page = await self.context.new_page()
        self.page.set_default_timeout(5000)
        self.errors = []
        self.page.on('pageerror', lambda e:self.errors.append(str(e)))
        self.external = []

    async def asyncTearDown(self):
        await self.browser.close()
        await self.pw.stop()

    async def open(self, path='/', sdk='fake'):
        async def route(request):
            url = request.request.url
            if '/vendor/supabase-' in url:
                if sdk == 'fake':
                    return await request.fulfill(body=FAKE_SDK,content_type='application/javascript')
                if sdk == 'missing':
                    return await request.abort()
            if url.startswith(self.url+'/') and request.request.method == 'GET':
                return await request.continue_()
            self.external.append((request.request.method,url))
            await request.abort()
        await self.context.route('**/*',route)
        await self.page.goto(self.url+path)
        await self.page.wait_for_function("document.getElementById('loading')?.style.display === 'none' || !document.getElementById('loading')")

    async def sign_in_locally(self):
        await self.page.evaluate("""()=>{S.user={id:'11111111-1111-4111-8111-111111111111',email:'test@example.test'};S.profile={username:'test',display_name:'Test'};showApp()}""")
        await self.page.wait_for_timeout(50)

    async def test_real_sdk_auth_accessibility_and_mobile(self):
        await self.open(sdk='real')
        self.assertTrue(await self.page.locator('#auth-view').is_visible())
        self.assertEqual(await self.page.locator('#auth-form input').evaluate_all('(els)=>els.every(e=>e.labels.length===1)'),True)
        await self.page.locator('#af-email').focus()
        for _ in range(3):
            await self.page.keyboard.press('Tab')
        self.assertEqual(await self.page.evaluate('document.activeElement.textContent'),'Join Free')
        await self.page.keyboard.press('Enter')
        self.assertTrue(await self.page.locator('#af-user').is_visible())
        for width in [320,390,768,1440]:
            await self.page.set_viewport_size({'width':width,'height':844})
            self.assertFalse(await self.page.evaluate('document.documentElement.scrollWidth>innerWidth'))
            self.assertTrue(await self.page.locator('#auth-form input').evaluate_all('(els)=>els.every(e=>e.getBoundingClientRect().right<=innerWidth)'))
        self.assertEqual(self.errors,[])

    async def test_authenticated_boot_creates_only_safe_profile_fields(self):
        await self.context.add_init_script("window.auditSession={user:{id:'11111111-1111-4111-8111-111111111111',email:'test@example.test',user_metadata:{username:'chosen'}}};window.auditMissingProfile=true")
        await self.open()
        self.assertTrue(await self.page.locator('#app-view').is_visible())
        self.assertTrue(await self.page.locator('.feed-post').count()>0)
        inserts=await self.page.evaluate("window.auditDb.calls.filter(c=>c.table==='profiles'&&c.method==='insert')")
        self.assertEqual(set(inserts[0]['args'][0]),{'id','username','display_name'})
        self.assertTrue(inserts[0]['args'][0]['username'].startswith('chosen_'))
        self.assertEqual(self.errors,[])

    async def test_missing_sdk_fails_visibly_and_legal_still_works(self):
        await self.open(sdk='missing')
        self.assertTrue(await self.page.locator('#auth-error').is_visible())
        self.assertTrue(await self.page.locator('#auth-submit-btn').is_disabled())
        await self.page.get_by_role('link',name='Terms',exact=True).click()
        self.assertIn('Terms of Service',await self.page.locator('#page').inner_text())
        self.assertEqual(self.errors,[])

    async def test_navigation_and_public_routes(self):
        await self.open()
        for route,text in [('terms','Terms of Service'),('privacy','Privacy Policy'),('creator','Creator Agreement'),('delete','Delete Account'),('child-safety','Child Safety Standards')]:
            await self.page.goto(self.url+'/#'+route)
            await self.page.wait_for_function("document.getElementById('page').textContent.trim().length>0")
            self.assertIn(text,await self.page.locator('#page').inner_text())
        await self.sign_in_locally()
        for tab in ['feed','live','shop','wealth','battles','safe','profile','settings','search']:
            await self.page.evaluate('(tab)=>navigate(tab)',tab)
            await self.page.wait_for_timeout(30)
            self.assertTrue((await self.page.locator('#page').inner_text()).strip(),tab)
            self.assertEqual(await self.page.evaluate("""()=>[...document.querySelectorAll('[onclick]')].flatMap(e=>{try{new Function(e.getAttribute('onclick'));return []}catch(err){return [err.message+':'+e.getAttribute('onclick')]}})"""),[],tab)
        await self.page.evaluate("navigate('settings','privacy_settings')")
        toggle=self.page.get_by_role('switch',name='Private Account')
        self.assertEqual(await toggle.get_attribute('aria-checked'),'false')
        await self.page.evaluate("window.auditDb.error={message:'failed'}")
        await toggle.click()
        self.assertEqual(await toggle.get_attribute('aria-checked'),'false')
        await self.page.evaluate('window.auditDb.error=null')
        await toggle.click()
        self.assertEqual(await toggle.get_attribute('aria-checked'),'true')
        self.assertEqual(self.errors,[])

    async def test_user_content_and_uuid_controls_are_safe(self):
        await self.open()
        await self.sign_in_locally()
        attack="O'Brien \" <img src=x onerror=window.auditXss=true>"
        await self.page.evaluate("""(attack)=>{S.postsLoaded=true;S.posts=[{id:'550e8400-e29b-41d4-a716-446655440000',creator_id:'22222222-2222-4222-8222-222222222222',title:attack,profiles:{display_name:attack,username:attack,avatar:attack},description:attack,likes:2}];navigate('feed')}""",attack)
        self.assertEqual(await self.page.locator('#page img').count(),0)
        self.assertEqual(await self.page.locator('.fp-header .text-button').first.inner_text(),attack)
        await self.page.locator('[id^=follow-]').click()
        self.assertTrue(await self.page.evaluate("S.followStatus['22222222-2222-4222-8222-222222222222']==='accepted'"))
        await self.page.locator('[id^=like-]').click()
        self.assertEqual(await self.page.locator('[id^=like-]').inner_text(),'❤️ 3')
        await self.page.locator('[id^=save-]').click()
        await self.page.evaluate("""(attack)=>{S.profile={display_name:attack,username:attack,bio:attack,avatar:attack,email:attack};navigate('profile')}""",attack)
        self.assertEqual(await self.page.locator('#page img').count(),0)
        await self.page.evaluate("""(attack)=>{S.shopItems=[{id:'test',name:attack,icon:attack,price:10,profiles:{display_name:attack}}];navigate('shop')}""",attack)
        self.assertEqual(await self.page.locator('#page img').count(),0)
        await self.page.locator('.sc-add').click()
        await self.page.evaluate('(attack)=>{window.auditName=attack;navigate("search")}',attack)
        await self.page.locator('#search-input').fill('test')
        await self.page.wait_for_function("document.getElementById('search-results').textContent.includes('O\\'Brien')")
        self.assertEqual(await self.page.locator('#search-results img').count(),0)
        self.assertFalse(await self.page.evaluate('window.auditXss===true'))
        self.assertEqual(self.errors,[])

    async def test_payments_never_grant_value_and_deletion_is_an_email(self):
        await self.open()
        await self.sign_in_locally()
        before=await self.page.evaluate('window.auditDb.calls.filter(c=>!c.rpc).length')
        await self.page.evaluate("S.coins=7;S.isPro=false;purchaseCoins();upgradeCreatorPro();requestWithdrawal();startGoLive();joinStream();")
        self.assertEqual(await self.page.evaluate('S.coins'),7)
        self.assertFalse(await self.page.evaluate('S.isPro'))
        self.assertEqual(await self.page.evaluate('window.auditDb.calls.filter(c=>!c.rpc).length'),before)
        await self.page.evaluate("navigate('settings','delete_account')")
        self.assertTrue(await self.page.get_by_role('button',name='Request account deletion',exact=True).is_visible())
        await self.page.locator('#confirm-deletion').check()
        await self.page.get_by_role('button',name='Request account deletion',exact=True).click()
        self.assertIn('Deletion request recorded',await self.page.locator('#auth-error').inner_text())
        self.assertEqual(self.errors,[])

    async def test_report_failure_does_not_claim_success(self):
        await self.open()
        await self.sign_in_locally()
        await self.page.evaluate("navigate('safe');window.auditDb.error={message:'unavailable'}")
        await self.page.locator('#report-url').fill('https://example.test/post')
        await self.page.locator('#report-details').fill('Please review this community violation.')
        await self.page.get_by_role('button',name='Submit Report',exact=True).click()
        self.assertIn('could not be sent',await self.page.locator('#report-status').inner_text())
        self.assertNotEqual(await self.page.locator('#report-details').input_value(),'')
        await self.page.evaluate('window.auditDb.error=null')
        await self.page.get_by_role('button',name='Submit Report',exact=True).click()
        self.assertEqual(await self.page.locator('#report-status').inner_text(),'Report received for review.')
        records=await self.page.evaluate("window.auditDb.calls.filter(c=>c.table==='reports'&&c.method==='insert')")
        self.assertIsNone(records[-1]['args'][0]['reported_id'])
        self.assertEqual(records[-1]['args'][0]['content_url'],'https://example.test/post')
        self.assertEqual(self.errors,[])

    async def test_creator_comments_messages_and_admin_forms(self):
        await self.open()
        await self.sign_in_locally()
        await self.page.evaluate("navigate('studio')")
        await self.page.locator('#content-title').fill('A new teaching')
        await self.page.locator('#content-description').fill('An encouraging message for our community.')
        await self.page.get_by_role('button',name='Submit for review',exact=True).click()
        await self.page.wait_for_function("window.auditDb.calls.some(c=>c.rpc==='save_content')")
        saved=await self.page.evaluate("window.auditDb.calls.find(c=>c.rpc==='save_content').args")
        self.assertEqual(saved['title'],'A new teaching')
        self.assertIsNone(saved['media_path'])
        await self.page.evaluate("navigate('feed')")
        await self.page.get_by_role('button',name='Comments',exact=True).first.click()
        await self.page.locator('#comment-body').fill('Thank you for sharing.')
        await self.page.get_by_role('button',name='Post comment',exact=True).click()
        await self.page.wait_for_function("window.auditDb.calls.some(c=>c.rpc==='add_comment')")
        await self.page.get_by_role('button',name='Close dialog',exact=True).click()
        await self.page.evaluate("navigate('messages')")
        await self.page.locator('#message-recipient').fill('test')
        await self.page.locator('#message-body').fill('Hello from a synthetic test.')
        await self.page.get_by_role('button',name='Send message',exact=True).click()
        await self.page.wait_for_function("window.auditDb.calls.some(c=>c.rpc==='send_message')")
        await self.page.evaluate("S.profile.role='admin';navigate('admin')")
        self.assertTrue(await self.page.get_by_role('heading',name='Account moderation',exact=True).is_visible())
        self.assertEqual(self.errors,[])

    async def test_service_worker_removes_only_legacy_caches(self):
        await self.context.close()
        self.context=await self.browser.new_context(service_workers='allow')
        self.page=await self.context.new_page()
        self.page.on('pageerror',lambda e:self.errors.append(str(e)))
        # Seed legacy state before the application's first registration. Waiting
        # for an identical-script update would not reliably trigger activation.
        await self.context.add_init_script("""
          const register=navigator.serviceWorker.register.bind(navigator.serviceWorker);
          navigator.serviceWorker.register=async(...args)=>{
            const old=await caches.open('ks-v3');
            await old.put('/',new Response('stale application'));
            await caches.open('unrelated-cache');
            return register(...args);
          };
        """)
        await self.open(sdk='real')
        await self.page.wait_for_function("async()=>!!navigator.serviceWorker.controller && !(await caches.keys()).includes('ks-v3')",timeout=10000)
        self.assertIn('unrelated-cache',await self.page.evaluate('caches.keys()'))
        await self.page.reload()
        self.assertTrue(await self.page.locator('#auth-view').is_visible())
        self.assertEqual(self.errors,[])

    async def test_mobile_menu_keyboard_and_content_width(self):
        await self.open()
        await self.sign_in_locally()
        for width in [320,390]:
            await self.page.set_viewport_size({'width':width,'height':844})
            await self.page.locator('#menu-btn').click()
            self.assertEqual(await self.page.locator('#menu-btn').get_attribute('aria-expanded'),'true')
            self.assertEqual(await self.page.evaluate('document.activeElement.textContent'),'Close menu')
            await self.page.keyboard.press('Shift+Tab')
            self.assertEqual(''.join((await self.page.evaluate('document.activeElement.textContent')).split()),'🔔Notifications')
            await self.page.keyboard.press('Escape')
            self.assertEqual(await self.page.evaluate('document.activeElement.id'),'menu-btn')
            for tab in ['feed','shop','wealth','safe','profile','settings','battles']:
                await self.page.evaluate('(tab)=>navigate(tab)',tab)
                await self.page.wait_for_timeout(30)
                dimensions=await self.page.locator('#page').evaluate('(e)=>[e.clientWidth,e.scrollWidth]')
                self.assertEqual(dimensions[0],dimensions[1],(width,tab))
        self.assertEqual(self.errors,[])

    async def test_legacy_redirect_and_manifest_assets(self):
        await self.open('/ks_live_deploy/?stream=test#terms')
        await self.page.wait_for_url(self.url+'/?stream=test#terms')
        self.assertIn('Terms of Service',await self.page.locator('#page').inner_text())
        manifest=(await self.page.request.get(self.url+'/manifest.json'))
        for icon in (await manifest.json())['icons']:
            response=await self.page.request.get(self.url+'/'+icon['src'].removeprefix('./'))
            self.assertEqual(response.status,200)
            self.assertTrue((await response.body()).startswith(b'\x89PNG\r\n\x1a\n'))
        for path in ['/.well-known/assetlinks.json','/robots.txt','/sitemap.xml']:
            self.assertEqual((await self.page.request.get(self.url+path)).status,200)
        self.assertEqual(self.errors,[])

if __name__=='__main__':
    unittest.main()
