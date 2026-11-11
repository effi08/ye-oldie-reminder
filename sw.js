importScripts('config.js');
const C='ye-oldie-v3';
self.addEventListener('install',e=>{e.waitUntil(self.skipWaiting())});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(k=>Promise.all(k.filter(x=>x!==C).map(x=>caches.delete(x)))).then(()=>self.clients.claim()))});
self.addEventListener('fetch',e=>{
  if(e.request.method!=='GET')return;
  e.respondWith(fetch(e.request).then(r=>{const c=r.clone();caches.open(C).then(x=>x.put(e.request,c));return r}).catch(()=>caches.match(e.request)));
});

// ---- Push: works with the app closed ----
self.addEventListener('push',e=>{
  let d={};try{d=e.data?e.data.json():{}}catch(_){}
  e.waitUntil((async()=>{
    const cs=await self.clients.matchAll({type:'window',includeUncontrolled:true});
    const vis=cs.find(c=>c.visibilityState==='visible');
    if(vis){vis.postMessage({type:'ring',id:d.id});return}   // app is open: ring in the app
    await self.registration.showNotification(d.title||'Reminder',{
      body:d.body||'Tap to open your reminder',
      tag:d.id||'reminder',renotify:true,requireInteraction:true,
      icon:'icon-192.png',badge:'icon-192.png',
      vibrate:[400,200,400,200,400],
      data:{id:d.id,device:d.device,date:d.date},
      actions:[{action:'done',title:'Done ✓'}]
    });
  })());
});
self.addEventListener('notificationclick',e=>{
  const n=e.notification,d=n.data||{};n.close();
  if(e.action==='done'){
    const CFG=self.YE_CFG||{};
    e.waitUntil(CFG.url&&d.device?fetch(CFG.url+'/rest/v1/rpc/ack_push',{method:'POST',headers:{'apikey':CFG.key,'Content-Type':'application/json'},body:JSON.stringify({p_device:d.device,p_rid:d.id,p_date:d.date})}).catch(()=>{}):Promise.resolve());
    return;
  }
  e.waitUntil(self.clients.matchAll({type:'window',includeUncontrolled:true}).then(cs=>{
    const c=cs[0];
    if(c){c.postMessage({type:'ring',id:d.id});return c.focus()}
    return self.clients.openWindow('./?ring='+encodeURIComponent(d.id||''));
  }));
});
