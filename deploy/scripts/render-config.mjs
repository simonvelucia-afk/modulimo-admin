// render-config.mjs — genere le config.js servi par l'appliance.
//
//   node scripts/render-config.mjs > generated/config.js
//
// Le fichier produit est monte par-dessus celui du depot : l'interface
// d'administration ne contient donc aucune URL ni cle en dur.

import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));

function readEnv(path) {
  const out = {};
  let raw = '';
  try { raw = readFileSync(path, 'utf8'); } catch { return out; }
  for (const line of raw.split('\n')) {
    const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/.exec(line);
    if (!m) continue;
    out[m[1]] = m[2].replace(/^["']|["']$/g, '');
  }
  return out;
}

const env = { ...readEnv(resolve(here, '..', '.env')),
              ...readEnv(resolve(here, '..', '.env.secrets')),
              ...process.env };

const need = (k) => {
  if (!env[k]) { console.error(`[render-config] variable manquante : ${k}`); process.exit(1); }
  return env[k];
};

const offline = String(env.OFFLINE_ASSETS || 'true') !== 'false';

const config = {
  instance: { id: env.INSTANCE_ID || 'modulimo-central', name: env.INSTANCE_NAME || 'Modulimo Central' },
  centralUrl: need('SITE_URL'),
  centralKey: need('ANON_KEY'),
  siteUrl: need('SITE_URL'),
  assets: offline
    ? { supabaseJs: 'vendor/supabase.js', favicon: 'vendor/favicon.png' }
    : {},
};

process.stdout.write(
  '/* Genere par deploy/scripts/render-config.mjs — ne pas modifier a la main. */\n' +
  'window.MODULIMO_CONFIG = ' + JSON.stringify(config, null, 2) + ';\n' +
  readFileSync(resolve(here, '..', '..', 'config.js'), 'utf8'),
);
