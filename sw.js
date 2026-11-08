/* YOUR PATH: fast cached startup with background update check. Never cache account/API responses. */
const VERSION='yp-golf-mastery-both-20261109-v1';
const CACHE='yourpath-shell-'+VERSION;
const CORE=['./index.html','./cloud-config.js','./manifest.webmanifest'];
const OPTIONAL=['./icon-192.png','./icon-512.png','./favicon.png','./apple-touch-icon.png','./your-path-mark.svg','./release-notes.json'];
const SUPABASE_CDN='https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.57.0/dist/umd/supabase.min.js';
const root=new URL('./',self.registration.scope);
const appUrl=new URL('./index.html',root).href;
const sameApp=(url)=>url.origin===root.origin&&url.pathname.startsWith(root.pathname);
self.addEventListener('install',event=>{
 event.waitUntil((async()=>{
  const cache=await caches.open(CACHE);
  await Promise.all([...CORE,...OPTIONAL].map(async path=>{
   try{
    const u=new URL(path,root);
    const r=await fetch(u,{cache:'reload'});
    if(!r.ok)return;
    if(r.headers.get('content-type')?.includes('text/html')&&!['./','./index.html'].includes(path))return;
    await cache.put(u.href,r);
   }catch(_){}
  }));
  await self.skipWaiting();
 })());
});
self.addEventListener('activate',event=>{
 event.waitUntil((async()=>{
  const keys=await caches.keys();
  await Promise.all(keys.filter(k=>/^(yourpath-|nextform-|ascension-)/.test(k)&&k!==CACHE).map(k=>caches.delete(k)));
  await self.clients.claim();
 })());
});
const inFlight=new Map();
async function refreshNavigation(request){
 const key=appUrl;
 if(inFlight.has(key))return inFlight.get(key);
 const work=(async()=>{
  try{
   const fresh=await fetch(new Request(appUrl,{cache:'no-store'}));
   if(!fresh.ok||!fresh.headers.get('content-type')?.includes('text/html'))return;
   const cache=await caches.open(CACHE);
   const old=await cache.match(appUrl);
   const etag=r=>r?.headers.get('etag')||null;
   const mod=r=>r?.headers.get('last-modified')||null;
   // The body comparison also handles GitHub hosting with absent or unchanged headers.
   let changed=false;
   if(old){
    if(etag(old)&&etag(fresh))changed=etag(old)!==etag(fresh);
    else if(mod(old)&&mod(fresh))changed=mod(old)!==mod(fresh);
    else changed=(await old.clone().text())!==(await fresh.clone().text());
   }
   if(!old||changed){
    await cache.put(appUrl,fresh.clone());
    if(changed){
     const clients=await self.clients.matchAll({type:'window',includeUncontrolled:true});
     for(const client of clients)client.postMessage({type:'YOUR_PATH_UPDATE_READY'});
    }
   }
  }catch(_){}
 })().finally(()=>inFlight.delete(key));
 inFlight.set(key,work);
 return work;
}
self.addEventListener('fetch',event=>{
 const request=event.request;
 if(request.method!=='GET')return;
 const url=new URL(request.url);
 const local=sameApp(url);
 const isLibrary=request.url===SUPABASE_CDN;
 if(!local&&!isLibrary)return;
 if(local&&request.mode==='navigate'){
  event.respondWith((async()=>{
   const cache=await caches.open(CACHE);
   const cached=await cache.match(appUrl);
   if(cached){event.waitUntil(refreshNavigation(request));return cached;}
   try{
    const fresh=await fetch(request);
    if(fresh.ok&&fresh.headers.get('content-type')?.includes('text/html')){
     event.waitUntil(cache.put(appUrl,fresh.clone()));
    }
    return fresh;
   }catch(_){return Response.error();}
  })());
  return;
 }
 event.respondWith((async()=>{
  const cache=await caches.open(CACHE);
  // Keep config and release notes fresh; public static images may load from cache.
  const networkFirst=local&&(/\/(cloud-config\.js|release-notes\.json)$/.test(url.pathname));
  if(!networkFirst){const saved=await cache.match(request);if(saved)return saved;}
  try{
   const response=await fetch(request,networkFirst?{cache:'no-store'}:undefined);
   if(response.ok||(isLibrary&&response.type==='opaque'))await cache.put(request,response.clone());
   return response;
  }catch(_){return(await cache.match(request))||Response.error();}
 })());
});
