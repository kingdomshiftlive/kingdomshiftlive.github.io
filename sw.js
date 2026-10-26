// Retire legacy cache-first HTML. Deployments are served by the network.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter(key => /^ks-v/.test(key)).map(key => caches.delete(key)));
    await self.clients.claim();
  })());
});
// Intentionally no fetch handler: never intercept API mutations or cache auth data.
