// render-index.mjs — prepare l'interface pour un reseau ferme.
//
//   node scripts/render-index.mjs > generated/index.html
//
// Remplace les URL tierces par leur equivalent dans vendor/. Fait ICI,
// a la construction : injecter ces scripts a l'execution exposerait la
// page a l'intervention du navigateur sur les scripts tiers bloquant
// l'analyseur, qui peut purement les bloquer sur connexion lente.

import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const target = process.argv[2] || 'index.html';

const REMPLACEMENTS = [
  ['https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2', 'vendor/supabase.js'],
  ['https://simonvelucia-afk.github.io/modulimo-home/images/favicon_Modulimo.png', 'vendor/favicon.png'],
];

let html = readFileSync(resolve(here, '..', '..', target), 'utf8');
let touches = 0;
for (const [de, vers] of REMPLACEMENTS) {
  if (!html.includes(de)) continue;
  html = html.split(de).join(vers);
  touches++;
}
if (touches === 0) {
  console.error(`[render-index] aucune URL distante trouvee dans ${target} — verifier REMPLACEMENTS`);
  process.exit(1);
}
process.stdout.write(html);
