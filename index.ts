import { createClient } from 'npm:@supabase/supabase-js@2.57.0';
const URL=Deno.env.get('SUPABASE_URL')!;
const ANON=Deno.env.get('SUPABASE_ANON_KEY')!;
const SERVICE=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const REDIRECT='https://condaminegolf.github.io/Ascension/';
const cors={'Access-Control-Allow-Origin':'https://condaminegolf.github.io','Access-Control-Allow-Headers':'authorization, apikey, content-type','Access-Control-Allow-Methods':'POST, OPTIONS','Content-Type':'application/json'};
const result=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers:cors});
const server=createClient(URL,SERVICE,{auth:{persistSession:false}});
const env=(key:string)=>{const v=Deno.env.get(key);if(!v)throw Error('Server configuration missing: '+key);return v};
async function tokenExchange(provider:string,fields:Record<string,string>){const endpoint=provider==='strava'?'https://www.strava.com/oauth/token':'https://api.ouraring.com/oauth/token';const resp=await fetch(endpoint,{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams(fields)});const data=await resp.json().catch(()=>({}));if(!resp.ok)throw Error(provider+' token exchange failed: '+(data.error_description||data.message||resp.status));return data}
async function authorizedToken(userId:string,provider:string){const {data,error}=await server.from('ascension_integrations').select('*').eq('user_id',userId).eq('provider',provider).maybeSingle();if(error)throw error;if(!data)throw Error('Connect '+provider+' first.');if(provider==='strava'&&(!data.expires_at||Date.parse(data.expires_at)<Date.now()+300000)){const fresh=await tokenExchange('strava',{client_id:env('STRAVA_CLIENT_ID'),client_secret:env('STRAVA_CLIENT_SECRET'),grant_type:'refresh_token',refresh_token:data.refresh_token});const patch={access_token:fresh.access_token,refresh_token:fresh.refresh_token,expires_at:new Date(fresh.expires_at*1000).toISOString(),updated_at:new Date().toISOString()};const {error:e}=await server.from('ascension_integrations').update(patch).eq('user_id',userId).eq('provider','strava');if(e)throw e;return patch.access_token;}return data.access_token}
async function getJson(url:string,token:string){const r=await fetch(url,{headers:{Authorization:'Bearer '+token}});if(!r.ok){const body=await r.text();throw Error('Provider returned '+r.status+': '+body.slice(0,220))}return await r.json()}
Deno.serve(async req=>{
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers:cors});
 if(req.method!=='POST')return result({error:'POST only'},405);
 try{
  const bearer=(req.headers.get('authorization')||'').replace(/^Bearer\s+/i,'');if(!bearer)return result({error:'Sign in required'},401);
  const auth=createClient(URL,ANON,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data:{user},error:authError}=await auth.auth.getUser(bearer);if(authError||!user)return result({error:'Invalid ASCENSION session'},401);
  const body=await req.json();const {action,provider}=body;
  if(action==='status'){const {data,error}=await server.from('ascension_integrations').select('provider').eq('user_id',user.id);if(error)throw error;return result({connected:{strava:(data||[]).some(x=>x.provider==='strava'),oura:(data||[]).some(x=>x.provider==='oura')}})}
  if(!['strava','oura'].includes(provider))return result({error:'Invalid provider'},400);
  if(action==='disconnect'){const {error}=await server.from('ascension_integrations').delete().eq('user_id',user.id).eq('provider',provider);if(error)throw error;return result({ok:true})}
  if(action==='exchange'){
   if(body.redirect_uri!==REDIRECT||typeof body.code!=='string'||body.code.length>2048)return result({error:'Invalid OAuth callback'},400);
   const id=env(provider==='strava'?'STRAVA_CLIENT_ID':'OURA_CLIENT_ID'),secret=env(provider==='strava'?'STRAVA_CLIENT_SECRET':'OURA_CLIENT_SECRET');
   const data=await tokenExchange(provider,{client_id:id,client_secret:secret,grant_type:'authorization_code',code:body.code,redirect_uri:REDIRECT});
   const expires=provider==='strava'?new Date(data.expires_at*1000).toISOString():data.expires_in?new Date(Date.now()+data.expires_in*1000).toISOString():null;
   const {error}=await server.from('ascension_integrations').upsert({user_id:user.id,provider,access_token:data.access_token,refresh_token:data.refresh_token||null,expires_at:expires,scopes:data.scope||null,external_user_id:data.athlete?.id?String(data.athlete.id):null,updated_at:new Date().toISOString()},{onConflict:'user_id,provider'});if(error)throw error;
   return result({ok:true,message:'You can now press Sync.'});
  }
  if(action==='sync'){
   const token=await authorizedToken(user.id,provider);
   if(provider==='strava'){
    // Last 90 days, capped to 200 items to avoid API exhaustion.
    const after=Math.floor((Date.now()-90*86400000)/1000);
    const activities=[];
    for(let page=1;page<=2;page++){const u=`https://www.strava.com/api/v3/athlete/activities?after=${after}&per_page=100&page=${page}`;const batch=await getJson(u,token);if(!Array.isArray(batch))throw Error('Unexpected Strava response');activities.push(...batch.map(x=>({id:x.id,sport_type:x.sport_type,type:x.type,distance:x.distance,moving_time:x.moving_time,start_date_local:x.start_date_local,start_date:x.start_date})));if(batch.length<100)break}
    return result({activities});
   }
   const start=new Date(Date.now()-13*86400000).toISOString().slice(0,10),end=new Date().toISOString().slice(0,10);
   const base='https://api.ouraring.com/v2/usercollection/';
   const [readiness,sleeps,sessions]=await Promise.all([getJson(base+`daily_readiness?start_date=${start}&end_date=${end}`,token),getJson(base+`daily_sleep?start_date=${start}&end_date=${end}`,token),getJson(base+`sleep?start_date=${start}&end_date=${end}`,token)]);
   const days=new Map<string,Record<string,unknown>>();
   for(const x of readiness.data||[])days.set(x.day,{date:x.day,readiness:x.score??null,sleep:null,hrv:null,restingHR:null});
   for(const x of sleeps.data||[]){const d=days.get(x.day)||{date:x.day,readiness:null,sleep:null,hrv:null,restingHR:null};d.sleep=x.score??null;days.set(x.day,d)}
   for(const x of sessions.data||[]){const d=days.get(x.day)||{date:x.day,readiness:null,sleep:null,hrv:null,restingHR:null};if(x.type==='long_sleep'||d.hrv==null){d.hrv=x.average_hrv??null;d.restingHR=x.lowest_heart_rate??null}days.set(x.day,d)}
   return result({recovery:[...days.values()]});
  }
  return result({error:'Unsupported action'},400);
 }catch(e){return result({error:e instanceof Error?e.message:'Unexpected integration error'},500)}
});
