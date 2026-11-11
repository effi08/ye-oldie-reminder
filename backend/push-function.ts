// Supabase Edge Function named: push   (turn OFF "Verify JWT" when deploying)
//   GET  ?action=key       -> returns the public VAPID key (created automatically on first use)
//   POST ?action=send-due  -> called every minute by cron; sends due notifications
import { createClient } from 'npm:@supabase/supabase-js@2';
import webpush from 'npm:web-push@3.6.7';

const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type' };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...cors, 'content-type': 'application/json' } });

async function vapid() {
  const got = await sb.from('vapid').select('*').eq('id', 1).maybeSingle();
  if (got.data) return got.data;
  const k = webpush.generateVAPIDKeys();
  await sb.from('vapid').upsert({ id: 1, public_key: k.publicKey, private_key: k.privateKey }, { ignoreDuplicates: true });
  return (await sb.from('vapid').select('*').eq('id', 1).single()).data;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  const action = new URL(req.url).searchParams.get('action');
  const k = await vapid();
  if (action === 'key') return json({ key: k.public_key });
  if (action !== 'send-due') return json({ error: 'unknown action' }, 400);

  webpush.setVapidDetails('https://effi08.github.io/ye-oldie-reminder/', k.public_key, k.private_key);
  const { data, error } = await sb.rpc('due_pushes');
  if (error) return json({ error: error.message }, 500);
  let sent = 0, dropped = 0;
  await Promise.all((data ?? []).map(async (d: any) => {
    const payload = JSON.stringify({ id: d.o_rid, device: d.o_device, title: d.o_title, body: d.o_nag ? 'Still waiting: tap to open your reminder' : 'Time for your reminder. Tap to open.', date: d.o_date, nag: d.o_nag });
    try {
      await webpush.sendNotification({ endpoint: d.o_endpoint, keys: { p256dh: d.o_p256dh, auth: d.o_auth } }, payload, { TTL: 600, urgency: 'high' });
      sent++;
    } catch (e: any) {
      if (e.statusCode === 404 || e.statusCode === 410) { await sb.rpc('drop_device', { p_device: d.o_device }); dropped++; }
    }
  }));
  return json({ due: data?.length ?? 0, sent, dropped });
});
