# Ye Oldie Reminder

Be reminded in your own way: your voice, your words, as often as you like.

- `index.html` patient app (installable PWA)
- `clinician.html` clinician adherence dashboard
- `backend/schema.sql` database + consent rules (Supabase)
- `config.js` backend URL and public key (blank = app runs standalone, no sharing)

Sharing is opt-in on both sides: the clinician creates a code, the patient must explicitly agree before any data is sent, and either side can stop at any time.
