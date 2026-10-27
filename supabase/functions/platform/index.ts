import {createClient} from '@supabase/supabase-js';
import Stripe from 'stripe';
import {createPlatformHandler} from '../_shared/platform.mjs';
import {issueZegoToken} from '../_shared/zego-token.mjs';
const env=(name:string)=>Deno.env.get(name)||'';
const mode=env('BILLING_MODE')||'disabled';
const stripeKey=env('STRIPE_SECRET_KEY');
if(mode==='test'&&stripeKey&&!stripeKey.startsWith('sk_test_'))throw new Error('Test mode requires a test Stripe key');
if(mode==='live'&&(!stripeKey.startsWith('sk_live_')||env('LIVE_BILLING_APPROVED')!=='true'))throw new Error('Live billing requires explicit approval and a matching key');
const stripe=stripeKey?new Stripe(stripeKey,{httpClient:Stripe.createFetchHttpClient()}):null;
const secret=env('ZEGO_SERVER_SECRET');
if(secret&&new TextEncoder().encode(secret).length!==32)throw new Error('Zego ServerSecret must be exactly 32 bytes; never use the exposed AppSign');
Deno.serve(createPlatformHandler({
 admin:createClient(env('SUPABASE_URL'),env('SUPABASE_SERVICE_ROLE_KEY'),{auth:{persistSession:false,autoRefreshToken:false}}),
 stripe,
 verifyWebhook:stripe&&env('STRIPE_WEBHOOK_SECRET')?(raw:string,signature:string)=>stripe.webhooks.constructEventAsync(raw,signature,env('STRIPE_WEBHOOK_SECRET'),undefined,Stripe.createSubtleCryptoProvider()):null,
 issueToken:secret?(input:{userId:string;roomId:string;host:boolean})=>issueZegoToken({...input,appId:Number(env('ZEGO_APP_ID')),secret}):null,
 settings:{webhookLiveMode:stripeKey.startsWith('sk_live_'),deletionProcessingEnabled:env('DELETION_PROCESSING_ENABLED')==='true',siteURL:env('SITE_URL')||'https://kingdomshiftlive.github.io/',allowedOrigins:env('ALLOWED_ORIGINS').split(',').filter(Boolean),billingMode:mode,liveBillingApproved:env('LIVE_BILLING_APPROVED')==='true',proEnabled:env('PRO_ENABLED')==='true',streamingEnabled:env('STREAMING_ENABLED')==='true',zegoAppId:Number(env('ZEGO_APP_ID'))}
}));
