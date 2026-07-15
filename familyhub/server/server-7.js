'use strict';
const express = require('express');
const Database = require('better-sqlite3');
const path = require('path');
const fs = require('fs');

const PORT     = parseInt(process.env.PORT) || 3001;
const DB_PATH  = process.env.DB_PATH        || '/data/familyhub.db';
const SECRET   = process.env.SECRET         || '';
const HA_TOKEN = process.env.HA_TOKEN       || '';
const HA_URL   = process.env.HA_URL         || 'http://supervisor/core';

const dbDir = path.dirname(DB_PATH);
if (!fs.existsSync(dbDir)) fs.mkdirSync(dbDir, { recursive: true });

const db = new Database(DB_PATH);
db.pragma('journal_mode = WAL');
db.exec(`CREATE TABLE IF NOT EXISTS store (key TEXT PRIMARY KEY, value TEXT, updated_at TEXT)`);

const app = express();
app.use(express.json({ limit: '20mb' }));

// CORS
app.use((req, res, next) => {
  res.header('Access-Control-Allow-Origin', '*');
  res.header('Access-Control-Allow-Methods', 'GET,POST,PUT,DELETE,OPTIONS');
  res.header('Access-Control-Allow-Headers', 'Content-Type,Authorization');
  if (req.method === 'OPTIONS') return res.sendStatus(204);
  next();
});

// Auth
const auth = (req, res, next) => {
  if (!SECRET) return next();
  const h = req.headers.authorization;
  if (h && h.replace('Bearer ', '') === SECRET) return next();
  res.status(401).json({ ok: false, error: 'Non autorise' });
};

const ok  = (res, data = {}) => res.json({ ok: true, ...data });
const err = (res, msg, code = 500) => res.status(code).json({ ok: false, error: msg });

// Health
app.get('/api/health', (req, res) => {
  ok(res, { version: '3.0.0', time: new Date().toISOString(), db: DB_PATH, ha: !!HA_TOKEN, addon: true });
});

// Data store
app.get('/api/data', auth, (req, res) => {
  const row = db.prepare('SELECT value FROM store WHERE key=?').get('familyhub');
  if (!row) return ok(res, { data: {} });
  try { ok(res, { data: JSON.parse(row.value) }); }
  catch (e) { err(res, 'Donnees corrompues'); }
});

app.post('/api/data', auth, (req, res) => {
  const data = req.body;
  if (!data || typeof data !== 'object') return err(res, 'Corps invalide', 400);
  db.prepare('INSERT OR REPLACE INTO store(key,value,updated_at) VALUES(?,?,?)').run(
    'familyhub', JSON.stringify(data), new Date().toISOString()
  );
  ok(res, { saved: true, time: new Date().toISOString() });
});

// HA: Presence
app.get('/api/ha/persons', auth, async (req, res) => {
  if (!HA_TOKEN) return err(res, 'Token HA non configure', 400);
  try {
    const r = await fetch(`${HA_URL}/api/states`, {
      headers: { Authorization: `Bearer ${HA_TOKEN}` }
    });
    if (!r.ok) return err(res, 'HA HTTP ' + r.status, r.status);
    const states = await r.json();
    const persons = states
      .filter(s => s.entity_id.startsWith('person.') || s.entity_id.startsWith('device_tracker.'))
      .map(s => ({
        entity_id: s.entity_id,
        name: s.attributes?.friendly_name || s.entity_id,
        state: s.state,
        last_changed: s.last_changed,
      }));
    ok(res, { persons });
  } catch (e) { err(res, 'Erreur HA: ' + e.message); }
});

// HA: Calendars
app.get('/api/ha/calendars', auth, async (req, res) => {
  if (!HA_TOKEN) return err(res, 'Token HA non configure', 400);
  const now = new Date();
  const start = now.toISOString();
  const end = new Date(now.getTime() + 30 * 24 * 60 * 60 * 1000).toISOString();
  try {
    const r = await fetch(`${HA_URL}/api/calendars`, {
      headers: { Authorization: `Bearer ${HA_TOKEN}` }
    });
    if (!r.ok) return err(res, 'HA HTTP ' + r.status, r.status);
    const cals = await r.json();
    const allEvents = [];
    for (const cal of cals) {
      try {
        const r2 = await fetch(`${HA_URL}/api/calendars/${cal.entity_id}?start=${start}&end=${end}`, {
          headers: { Authorization: `Bearer ${HA_TOKEN}` }
        });
        if (!r2.ok) continue;
        const evts = await r2.json();
        evts.forEach(e => allEvents.push({
          calendar: cal.name || cal.entity_id,
          summary: e.summary,
          start: e.start?.dateTime || e.start?.date,
          end: e.end?.dateTime || e.end?.date,
          location: e.location || '',
        }));
      } catch (e2) {}
    }
    ok(res, { calendars: cals, events: allEvents });
  } catch (e) { err(res, 'Erreur HA: ' + e.message); }
});

// HA: Trigger service
app.post('/api/ha/service', auth, async (req, res) => {
  if (!HA_TOKEN) return err(res, 'Token HA non configure', 400);
  const { domain, service, data = {} } = req.body;
  if (!domain || !service) return err(res, 'domain et service requis', 400);
  try {
    const r = await fetch(`${HA_URL}/api/services/${domain}/${service}`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${HA_TOKEN}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(data)
    });
    if (!r.ok) return err(res, 'HA HTTP ' + r.status, r.status);
    ok(res, { triggered: true });
  } catch (e) { err(res, 'Erreur HA: ' + e.message); }
});

// Webhook: HA -> FamilyHub
app.post('/api/webhook', (req, res) => {
  const event = req.body;
  const row = db.prepare('SELECT value FROM store WHERE key=?').get('ha_events');
  let events = [];
  if (row) { try { events = JSON.parse(row.value); } catch (e) {} }
  events.unshift({ ...event, received_at: new Date().toISOString() });
  events = events.slice(0, 50);
  db.prepare('INSERT OR REPLACE INTO store(key,value,updated_at) VALUES(?,?,?)').run(
    'ha_events', JSON.stringify(events), new Date().toISOString()
  );
  ok(res, { received: true });
});

// HA events poll
app.get('/api/ha/events', auth, (req, res) => {
  const row = db.prepare('SELECT value FROM store WHERE key=?').get('ha_events');
  if (!row) return ok(res, { events: [] });
  try {
    ok(res, { events: JSON.parse(row.value) });
    db.prepare('INSERT OR REPLACE INTO store(key,value,updated_at) VALUES(?,?,?)').run(
      'ha_events', '[]', new Date().toISOString()
    );
  } catch (e) { ok(res, { events: [] }); }
});

// 404
app.use((req, res) => res.status(404).json({ ok: false, error: `Route inconnue: ${req.method} ${req.path}` }));

// Start
app.listen(PORT, '0.0.0.0', () => {
  console.log(`\nFamilyHub API v3.0.0`);
  console.log(`  Port   : ${PORT}`);
  console.log(`  DB     : ${DB_PATH}`);
  console.log(`  Auth   : ${SECRET ? 'oui' : 'non'}`);
  console.log(`  HA API : ${HA_TOKEN ? 'oui' : 'non'}\n`);
});

process.on('SIGTERM', () => { db.close(); process.exit(0); });
process.on('SIGINT',  () => { db.close(); process.exit(0); });
