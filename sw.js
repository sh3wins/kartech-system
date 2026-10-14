/* Kartech Workshop: lets the owner add this to her phone's home screen.
   It always loads the newest version from the internet. */
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', e => { e.respondWith(fetch(e.request)); });
