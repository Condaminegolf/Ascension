/* YOUR PATH — resilient offline support (2026-11-03).
 * Do not cache API, user, Supabase, Strava, or Oura responses.
 */
const VERSION = 'yp-20261103-safe-cache-v1';
const CACHE = 'yourpath-shell-' + VERSION;
const CORE = ['./', './index.html', './cloud-config.js', './manifest.webmanifest'];
const OPTIONAL = ['./icon-192.png','./icon-512.png','./favicon.png','./apple-touch-icon.png','./your-path-mark.svg','./release-notes.json'];
const SUPABASE_CDN = 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.57.0/dist/umd/supabase.min.js';

self.addEventListener('install', event => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    // Fetch each asset independently: one missing image must not prevent activation.
    await Promise.all([...CORE, ...OPTIONAL].map(async path => {
      try {
        const url = new URL(path, self.registration.scope);
        const response = await fetch(url, {cache:'reload'});
        if (response.ok && response.headers.get('content-type')?.includes('text/html') && !path.endsWith('.html') && path !== './') return;
        if (response.ok) await cache.put(url.href, response);
      } catch (_) { /* Network interruptions cannot block worker installation. */ }
    }));
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter(key =>
      (key.startsWith('yourpath-') || key.startsWith('nextform-') || key.startsWith('ascension-')) && key !== CACHE
    ).map(key => caches.delete(key)));
    await self.clients.claim();
  })());
});

const scopePath = new URL('./', self.registration.scope).pathname;
self.addEventListener('fetch', event => {
  const request = event.request;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);
  const local = url.origin === self.location.origin && url.pathname.startsWith(scopePath);
  const isLibrary = request.url === SUPABASE_CDN;
  if (!local && !isLibrary) return; // All remote integration/API requests use the network directly.
  if (local && request.mode === 'navigate') {
    event.respondWith((async () => {
      try {
        const response = await fetch(request, {cache: 'no-store'});
        if (response.ok) {
          const cache = await caches.open(CACHE);
          await cache.put(new URL('./index.html', self.registration.scope).href, response.clone());
        }
        return response;
      } catch (_) {
        const cache = await caches.open(CACHE);
        return (await cache.match(new URL('./index.html', self.registration.scope).href)) || Response.error();
      }
    })());
    return;
  }
  event.respondWith((async () => {
    const cache = await caches.open(CACHE);
    // Critical app files are network-first: users get the newly uploaded build.
    const networkFirst = local && (url.pathname.endsWith('/index.html') || url.pathname.endsWith('/cloud-config.js') || url.pathname.endsWith('/release-notes.json'));
    if (!networkFirst) {
      const cached = await cache.match(request);
      if (cached) return cached;
    }
    try {
      const response = await fetch(request, networkFirst ? {cache: 'no-store'} : undefined);
      if (response.ok || (isLibrary && response.type === 'opaque')) await cache.put(request, response.clone());
      return response;
    } catch (_) {
      return (await cache.match(request)) || Response.error();
    }
  })());
});
