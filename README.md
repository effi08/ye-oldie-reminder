# Ye Oldie Reminder

Be reminded in your own way: your voice, your words, as often as you like.

- `index.html` patient app (installable PWA)
- `clinician.html` clinician adherence dashboard
- `backend/schema.sql` database + consent rules (Supabase)
- `config.js` backend URL and public key (blank = app runs standalone, no sharing)

Sharing is opt-in on both sides: the clinician creates a code, the patient must explicitly agree before any data is sent, and either side can stop at any time.

## Push alerts (closed-app notifications)
`backend/push.sql` + `backend/push-function.ts` (Supabase). The phone sends only a random device id, push address, reminder title, time and timezone. A cron job calls the Edge Function every minute; it sends a push at the reminder time, then every 2 minutes (max 20) until the person taps Done.
