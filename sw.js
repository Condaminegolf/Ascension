/* YOUR PATH app shell offline cache. Private Supabase/Strava/Oura requests are never cached. */
const VERSION='yp-gold-strength-trials-20261101-v1';
const SHELL='yourpath-shell-'+VERSION;
const STATIC=['./','./index.html','./cloud-config.js','./manifest.webmanifest','./icon-192.png','./icon-512.png','./favicon.png','./apple-touch-icon.png','./your-path-mark.svg','./release-notes.json'];
const SUPABASE_CDN='https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.57.0/dist/umd/supabase.min.js';
self.addEventListener('install',event=>{event.waitUntil((async()=>{
 const cache=await caches.open(SHELL);
 await cache.addAll(STATIC);
 // A cached, pinned UMD file allows signed-in sessions to read local data offline.
 try{const response=await fetch(SUPABASE_CDN,{mode:'no-cors'});if(response.ok||response.type==='opaque')await cache.put(SUPABASE_CDN,response);}catch(_){/* offline first install: shell still works */}
 await self.skipWaiting();
})());});
self.addEventListener('activate',event=>{event.waitUntil((async()=>{
 const keys=await caches.keys();await Promise.all(keys.filter(k=>k.startsWith('yourpath-')&&k!==SHELL).map(k=>caches.delete(k)));
 await self.clients.claim();
})());});
const shellPath=new URL('./',self.registration.scope).pathname;
self.addEventListener('fetch',event=>{
 const request=event.request;if(request.method!=='GET')return;
 const url=new URL(request.url);
 const local=url.origin===self.location.origin&&url.pathname.startsWith(shellPath);
 if(!local&&request.url!==SUPABASE_CDN)return;
 if(local&&request.mode==='navigate'){
  event.respondWith((async()=>{
   const cache=await caches.open(SHELL);
   try{
    const controller=new AbortController();const timeout=setTimeout(()=>controller.abort(),3500);
    const response=await fetch(request,{signal:controller.signal,cache:'no-store'}).finally(()=>clearTimeout(timeout));
    if(response.ok)await cache.put(new URL('./index.html',self.registration.scope).href,response.clone());
    return response;
   }catch(_){return (await cache.match(new URL('./index.html',self.registration.scope).href))||Response.error()}
  })());return;
 }
 if(local||request.url===SUPABASE_CDN){
  event.respondWith((async()=>{const cache=await caches.open(SHELL);const cached=await cache.match(request);if(cached)return cached;try{const response=await fetch(request);if(response.ok||response.type==='opaque')await cache.put(request,response.clone());return response}catch(_){return Response.error()}})());
 }
});