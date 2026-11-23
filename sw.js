self.addEventListener('push', event => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch (_) {}
  event.waitUntil(self.registration.showNotification(data.title || 'تنبيه RIZQ', {
    body: data.body || 'لديك تحديث جديد في لوحة الإدارة',
    icon: '/rizq-icon.svg', badge: '/rizq-icon.svg',
    tag: data.tag || 'rizq-admin-update', renotify: true,
    data: { url: data.url || '/' }
  }));
});
self.addEventListener('notificationclick', event => {
  event.notification.close();
  const target = new URL(event.notification.data?.url || '/', self.location.origin).href;
  event.waitUntil((async () => {
    const list = await clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const client of list) if (client.url.startsWith(self.location.origin)) {
      await client.focus(); if ('navigate' in client) await client.navigate(target); return;
    }
    if (clients.openWindow) await clients.openWindow(target);
  })());
});