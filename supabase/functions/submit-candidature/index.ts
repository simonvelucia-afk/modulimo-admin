// ============================================================
// MODULIMO -- Edge Function : submit-candidature
// ============================================================
// Recoit le formulaire public, calcule le score cote serveur
// (jamais expose au candidat), insere dans public.candidatures,
// puis notifie le gestionnaire de l'immeuble par courriel
// (fire-and-forget, ne bloque pas la reponse au candidat).
//
// Deploiement :
//   supabase functions deploy submit-candidature --no-verify-jwt
// ============================================================

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

interface ScoreBreakdown {
  finances: { score: number; max: number; details: string };
  emploi: { score: number; max: number; details: string };
  stabilite: { score: number; max: number; details: string };
  references: { score: number; max: number; details: string };
  declarations: { score: number; max: number; details: string };
  consentements: { score: number; max: number; details: string };
  cohabitat: { score: number; max: number; details: string };
  valeurs: {
    score: number; max: number;
    environnement: number; securite: number; innovation: number;
    details: string;
  };
  completude: { score: number; max: number; details: string };
  total: number;
  category: 'excellent' | 'bon' | 'a_evaluer' | 'a_risque';
  flags: string[];
}

function num(v: unknown): number {
  const n = parseFloat(String(v ?? '').replace(/[^\d.-]/g, ''));
  return isNaN(n) ? 0 : n;
}
function bool(v: unknown): boolean {
  return v === true || v === 'true' || v === 'on' || v === 1 || v === '1';
}
function monthsSince(dateStr: unknown): number {
  if (!dateStr) return 0;
  const d = new Date(String(dateStr));
  if (isNaN(d.getTime())) return 0;
  const months = (Date.now() - d.getTime()) / (1000 * 60 * 60 * 24 * 30.44);
  return Math.max(0, months);
}

function calculateScore(formData: Record<string, unknown>): ScoreBreakdown {
  const flags: string[] = [];
  // deno-lint-ignore no-explicit-any
  const breakdown: any = {};

  const targetRent = num(formData.target_rent);
  const totalAnnualIncome = num(formData.annual_income) + num(formData.co_income);
  const monthlyIncome = totalAnnualIncome / 12;
  let financesScore = 0;
  let financesDetails = "Revenu insuffisant pour evaluation";
  if (targetRent > 0 && monthlyIncome > 0) {
    const ratio = (targetRent / monthlyIncome) * 100;
    if (ratio <= 25)      { financesScore = 22; financesDetails = `Excellent ratio (${ratio.toFixed(1)}%)`; }
    else if (ratio <= 30) { financesScore = 19; financesDetails = `Tres bon ratio (${ratio.toFixed(1)}%)`; }
    else if (ratio <= 35) { financesScore = 14; financesDetails = `Bon ratio (${ratio.toFixed(1)}%)`; }
    else if (ratio <= 40) { financesScore = 8;  financesDetails = `Ratio limite (${ratio.toFixed(1)}%)`; }
    else                  { financesScore = 2;  financesDetails = `Ratio preoccupant (${ratio.toFixed(1)}%)`;
                            flags.push("Ratio loyer/revenu superieur a 40%"); }
  } else {
    flags.push("Donnees financieres manquantes");
  }
  breakdown.finances = { score: financesScore, max: 22, details: financesDetails };

  const empType = String(formData.employment_type ?? '');
  const empMonths = monthsSince(formData.employment_since);
  let empScore = 0;
  const typeScores: Record<string, number> = {
    permanent_temps_plein: 6, permanent_temps_partiel: 4, autonome: 4,
    retraite: 5, temporaire: 2, etudiant: 2, autre: 1,
  };
  empScore += typeScores[empType] ?? 0;
  if (empMonths >= 36) empScore += 4;
  else if (empMonths >= 18) empScore += 3;
  else if (empMonths >= 6) empScore += 2;
  else if (empMonths > 0) empScore += 1;
  empScore = Math.min(empScore, 10);
  breakdown.emploi = { score: empScore, max: 10, details: `${empType || 'non precise'} · ${Math.round(empMonths)} mois` };

  const residenceMonths = monthsSince(formData.current_since);
  let resScore = 0;
  if (residenceMonths >= 36) resScore = 8;
  else if (residenceMonths >= 24) resScore = 7;
  else if (residenceMonths >= 12) resScore = 5;
  else if (residenceMonths >= 6) resScore = 3;
  else if (residenceMonths > 0) resScore = 1;
  breakdown.stabilite = { score: resScore, max: 8, details: `${Math.round(residenceMonths)} mois a l'adresse actuelle` };

  let refScore = 0;
  const refsComplete: string[] = [];
  if (formData.current_landlord_phone && formData.current_landlord) { refScore += 2; refsComplete.push("proprietaire actuel"); }
  if (formData.ref1_name && formData.ref1_phone) { refScore += 2; refsComplete.push("ref. 1"); }
  if (formData.ref2_name && formData.ref2_phone) { refScore += 2; refsComplete.push("ref. 2"); }
  breakdown.references = { score: refScore, max: 6, details: refsComplete.length ? refsComplete.join(", ") : "aucune reference complete" };

  let decScore = 10;
  const decFlags: string[] = [];
  if (formData.dec_tal === 'oui')        { decScore -= 2; decFlags.push("TAL"); }
  if (formData.dec_eviction === 'oui')   { decScore -= 4; decFlags.push("expulsion"); flags.push("Expulsion anterieure declaree"); }
  if (formData.dec_bankruptcy === 'oui') { decScore -= 2; decFlags.push("faillite"); }
  if (formData.dec_lawsuit === 'oui')    { decScore -= 4; decFlags.push("poursuite en cours"); flags.push("Poursuite pour non-paiement en cours"); }
  decScore = Math.max(0, decScore);
  breakdown.declarations = { score: decScore, max: 10, details: decFlags.length ? `Signalements : ${decFlags.join(", ")}` : "Aucun signalement" };

  let consScore = 0;
  if (bool(formData.consent_credit))     consScore += 2;
  if (bool(formData.consent_employer))   consScore += 1;
  if (bool(formData.consent_landlord))   consScore += 2;
  if (bool(formData.consent_references)) consScore += 1;
  breakdown.consentements = { score: consScore, max: 6, details: `${consScore}/6 consentements donnes` };

  let chScore = 0;
  const digital = num(formData.digital_comfort);
  if (digital >= 4) chScore += 3;
  else if (digital === 3) chScore += 2;
  else if (digital >= 1) chScore += 1;
  if (formData.payment_pref === 'cohabitat_auto') chScore += 3;
  else if (formData.payment_pref === 'cohabitat_manuel') chScore += 2;
  else if (formData.payment_pref === 'autre') chScore += 1;
  if (formData.comm_pref === 'cohabitat') chScore += 2;
  else if (formData.comm_pref === 'email') chScore += 1;
  const chServices = ['ch_salle_commune','ch_autopartage','ch_babillard','ch_atelier','ch_reseau','ch_evenements'];
  const chCount = chServices.filter(s => bool(formData[s])).length;
  chScore += Math.min(10, chCount * 2);
  chScore = Math.min(chScore, 18);
  breakdown.cohabitat = { score: chScore, max: 18, details: `${chCount}/${chServices.length} services · paiement: ${formData.payment_pref || '--'}` };

  let ecoScore = 0;
  const ecoImp = num(formData.eco_importance);
  if (ecoImp >= 4) ecoScore += 2;
  else if (ecoImp === 3) ecoScore += 1;
  const ecoHabits = ['eco_recyclage','eco_compost','eco_transport','eco_ve','eco_local','eco_economie','eco_jardinage'];
  const ecoCount = ecoHabits.filter(h => bool(formData[h])).length;
  ecoScore += Math.min(3, Math.floor(ecoCount * 0.6));
  ecoScore = Math.min(5, ecoScore);

  let secScore = 0;
  const secImp = num(formData.sec_importance);
  if (secImp >= 4) secScore += 1;
  if (formData.sec_cameras === 'favorable' || formData.sec_cameras === 'acceptable') secScore += 2;
  else if (formData.sec_cameras === 'reserve') secScore += 1;
  else if (formData.sec_cameras === 'defavorable') flags.push("Defavorable aux cameras de securite");
  const secBeh = num(formData.sec_behavior);
  if (secBeh >= 4) secScore += 2;
  else if (secBeh === 3) secScore += 1;
  secScore = Math.min(5, secScore);

  let innScore = 0;
  const innOpen = num(formData.inn_openness);
  if (innOpen >= 4) innScore += 2;
  else if (innOpen === 3) innScore += 1;
  const innTopics = ['inn_mobilite','inn_iot','inn_agriculture','inn_energie','inn_communaute','inn_diy'];
  const innCount = innTopics.filter(t => bool(formData[t])).length;
  innScore += Math.min(2, Math.floor(innCount / 2));
  if (typeof formData.inn_idea === 'string' && formData.inn_idea.trim().length > 20) innScore += 1;
  innScore = Math.min(5, innScore);

  const valeursTotal = ecoScore + secScore + innScore;
  breakdown.valeurs = {
    score: valeursTotal, max: 15,
    environnement: ecoScore, securite: secScore, innovation: innScore,
    details: `Eco ${ecoScore}/5 · Sec ${secScore}/5 · Innov ${innScore}/5`,
  };

  const requiredFields = ['last_name','first_name','email','phone_cell','current_address','employer','annual_income','target_rent'];
  const filled = requiredFields.filter(f => formData[f] && String(formData[f]).trim() !== '').length;
  const compScore = Math.round((filled / requiredFields.length) * 5);
  breakdown.completude = { score: compScore, max: 5, details: `${filled}/${requiredFields.length} champs critiques remplis` };

  const total = financesScore + empScore + resScore + refScore + decScore + consScore + chScore + valeursTotal + compScore;
  let category: 'excellent' | 'bon' | 'a_evaluer' | 'a_risque';
  if (total >= 80) category = 'excellent';
  else if (total >= 65) category = 'bon';
  else if (total >= 50) category = 'a_evaluer';
  else category = 'a_risque';
  if (flags.some(f => f.includes("Expulsion") || f.includes("Poursuite"))) {
    if (category === 'excellent') category = 'bon';
    else if (category === 'bon') category = 'a_evaluer';
  }
  breakdown.total = total;
  breakdown.category = category;
  breakdown.flags = flags;
  return breakdown as ScoreBreakdown;
}

// ============================================================
// Construction du courriel HTML envoye au gestionnaire
// ============================================================
// deno-lint-ignore no-explicit-any
function buildEmailHtml(candidatureId: string, buildingName: string, fd: any, score: ScoreBreakdown, consents: any): string {
  const catColors: Record<string, string> = {
    excellent: '#2f7a4d', bon: '#1f4e79', a_evaluer: '#b8860b', a_risque: '#a94442',
  };
  const catColor = catColors[score.category] || '#666';
  const flagsHtml = score.flags && score.flags.length
    ? `<div style="background:#fbeae9;border-left:3px solid #a94442;padding:12px 16px;margin:16px 0;border-radius:4px;color:#6b2a28;font-size:14px"><strong>⚠ Points d'attention :</strong><br>${score.flags.map(f => '• ' + f).join('<br>')}</div>`
    : '';
  const row = (label: string, b: { score: number; max: number; details?: string }) =>
    `<tr><td style="padding:6px 0;border-bottom:1px solid #f0eee7">${label}<div style="font-size:11px;color:#888">${b.details || ''}</div></td><td style="text-align:right;padding:6px 0;border-bottom:1px solid #f0eee7;white-space:nowrap"><strong>${b.score}</strong> / ${b.max}</td></tr>`;

  return `<!DOCTYPE html><html><body style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;line-height:1.55;color:#1a1a18;background:#f4f3f0;margin:0;padding:24px">
<div style="max-width:680px;margin:0 auto;background:#fff;border:1px solid #d0cec8;border-radius:8px;overflow:hidden">
  <div style="background:#1e3d32;color:#fff;padding:24px 32px">
    <div style="font-size:11px;letter-spacing:.3em;text-transform:uppercase;opacity:.7;margin-bottom:4px">Modulimo · ${buildingName}</div>
    <h1 style="margin:0;font-size:22px;font-weight:800;letter-spacing:-.02em">Nouvelle candidature locataire</h1>
  </div>

  <div style="padding:24px 32px">
    <div style="display:flex;justify-content:space-between;align-items:center;gap:16px;flex-wrap:wrap;margin-bottom:8px">
      <div>
        <h2 style="margin:0 0 4px;font-size:20px">${fd.first_name || ''} ${fd.last_name || ''}</h2>
        <div style="font-size:14px;color:#5c5c56"><a href="mailto:${fd.email || ''}" style="color:#2d5a4a">${fd.email || ''}</a> · ${fd.phone_cell || ''}</div>
      </div>
      <div style="background:${catColor};color:#fff;padding:8px 16px;border-radius:4px;text-align:center;min-width:100px">
        <div style="font-size:24px;font-weight:800;line-height:1">${score.total}<span style="font-size:13px;opacity:.8">/100</span></div>
        <div style="font-size:10px;letter-spacing:.12em;text-transform:uppercase;margin-top:4px">${score.category.replace('_',' ')}</div>
      </div>
    </div>

    ${flagsHtml}

    <h3 style="margin:24px 0 8px;font-size:15px;color:#1e3d32;border-bottom:1px solid #d0cec8;padding-bottom:6px">Détail du score</h3>
    <table style="width:100%;border-collapse:collapse;font-size:13px">
      ${row('Capacité financière', score.finances)}
      ${row("Stabilité d'emploi", score.emploi)}
      ${row('Stabilité résidentielle', score.stabilite)}
      ${row('Références', score.references)}
      ${row('Déclarations', score.declarations)}
      ${row('Consentements Loi 25', score.consentements)}
      ${row('Engagement CoHabitat', score.cohabitat)}
      ${row('Valeurs Modulimo (Eco/Séc/Innov)', score.valeurs)}
      ${row('Complétude du dossier', score.completude)}
    </table>

    <h3 style="margin:24px 0 8px;font-size:15px;color:#1e3d32;border-bottom:1px solid #d0cec8;padding-bottom:6px">Identité et ménage</h3>
    <ul style="font-size:13px;line-height:1.7;padding-left:18px;margin:0">
      <li><strong>Né en :</strong> ${fd.birth_year || '—'} · <strong>Statut Canada :</strong> ${fd.status_canada || '—'}</li>
      <li><strong>Tél. jour :</strong> ${fd.phone_day || '—'}</li>
      <li><strong>Co-demandeur :</strong> ${fd.co_name || '—'} ${fd.co_relation ? '(' + fd.co_relation + ')' : ''} · ${fd.co_phone || ''} · ${fd.co_email || ''}</li>
      <li><strong>Ménage :</strong> ${fd.adults || '?'} adulte(s) + ${fd.children || '0'} enfant(s)${fd.child_ages ? ' — âges ' + fd.child_ages : ''}</li>
      <li><strong>Animaux :</strong> ${fd.pets || 'aucun'}</li>
    </ul>

    <h3 style="margin:24px 0 8px;font-size:15px;color:#1e3d32;border-bottom:1px solid #d0cec8;padding-bottom:6px">Logement actuel</h3>
    <ul style="font-size:13px;line-height:1.7;padding-left:18px;margin:0">
      <li>${fd.current_address || '—'}</li>
      <li><strong>Statut :</strong> ${fd.current_tenancy || '—'} depuis ${fd.current_since || '—'}</li>
      <li><strong>Loyer actuel :</strong> ${fd.current_rent ? fd.current_rent + ' $' : '—'}</li>
      <li><strong>Propriétaire actuel :</strong> ${fd.current_landlord || '—'} ${fd.current_landlord_phone ? '· ' + fd.current_landlord_phone : ''}</li>
      ${fd.move_reason ? `<li><strong>Raison du déménagement :</strong> ${fd.move_reason}</li>` : ''}
    </ul>

    <h3 style="margin:24px 0 8px;font-size:15px;color:#1e3d32;border-bottom:1px solid #d0cec8;padding-bottom:6px">Emploi et revenus</h3>
    <ul style="font-size:13px;line-height:1.7;padding-left:18px;margin:0">
      <li><strong>${fd.employer || '—'}</strong> — ${fd.position || '—'} (${fd.employment_type || '—'}) depuis ${fd.employment_since || '—'}</li>
      <li><strong>Revenu annuel :</strong> ${fd.annual_income ? fd.annual_income + ' $' : '—'}</li>
      <li><strong>Co-demandeur :</strong> ${fd.co_employer || '—'} · ${fd.co_income ? fd.co_income + ' $' : '—'}</li>
      <li><strong>Loyer convoité :</strong> <span style="font-weight:700">${fd.target_rent ? fd.target_rent + ' $' : '—'}</span> · occupation souhaitée ${fd.move_in_date || '—'}</li>
    </ul>

    <h3 style="margin:24px 0 8px;font-size:15px;color:#1e3d32;border-bottom:1px solid #d0cec8;padding-bottom:6px">Références</h3>
    <ul style="font-size:13px;line-height:1.7;padding-left:18px;margin:0">
      <li>${fd.ref1_name || '—'} ${fd.ref1_relation ? '(' + fd.ref1_relation + ')' : ''} · ${fd.ref1_phone || ''} · ${fd.ref1_email || ''}</li>
      <li>${fd.ref2_name || '—'} ${fd.ref2_relation ? '(' + fd.ref2_relation + ')' : ''} · ${fd.ref2_phone || ''} · ${fd.ref2_email || ''}</li>
    </ul>

    <h3 style="margin:24px 0 8px;font-size:15px;color:#1e3d32;border-bottom:1px solid #d0cec8;padding-bottom:6px">Déclarations</h3>
    <ul style="font-size:13px;line-height:1.7;padding-left:18px;margin:0">
      <li>TAL : <strong>${fd.dec_tal || '—'}</strong> · Expulsion : <strong>${fd.dec_eviction || '—'}</strong> · Faillite : <strong>${fd.dec_bankruptcy || '—'}</strong> · Poursuite : <strong>${fd.dec_lawsuit || '—'}</strong></li>
      ${fd.dec_explain ? `<li><strong>Explications :</strong> ${fd.dec_explain}</li>` : ''}
    </ul>

    <h3 style="margin:24px 0 8px;font-size:15px;color:#1e3d32;border-bottom:1px solid #d0cec8;padding-bottom:6px">Préférences CoHabitat</h3>
    <ul style="font-size:13px;line-height:1.7;padding-left:18px;margin:0">
      <li>Aisance numérique : ${fd.digital_comfort ? fd.digital_comfort + '/5' : '—'}</li>
      <li>Mode de paiement préféré : ${fd.payment_pref || '—'}</li>
      <li>Communication préférée : ${fd.comm_pref || '—'}</li>
    </ul>

    <h3 style="margin:24px 0 8px;font-size:15px;color:#1e3d32;border-bottom:1px solid #d0cec8;padding-bottom:6px">Valeurs Modulimo</h3>
    <ul style="font-size:13px;line-height:1.7;padding-left:18px;margin:0">
      <li>Environnement : importance ${fd.eco_importance || '—'}/5 · ${score.valeurs.environnement}/5 pts</li>
      <li>Sécurité : importance ${fd.sec_importance || '—'}/5 · caméras = ${fd.sec_cameras || '—'} · ${score.valeurs.securite}/5 pts</li>
      <li>Innovation : ouverture ${fd.inn_openness || '—'}/5 · ${score.valeurs.innovation}/5 pts</li>
      ${fd.inn_idea ? `<li><strong>Idée proposée :</strong> ${fd.inn_idea}</li>` : ''}
    </ul>

    <h3 style="margin:24px 0 8px;font-size:15px;color:#1e3d32;border-bottom:1px solid #d0cec8;padding-bottom:6px">Consentements Loi 25</h3>
    <ul style="font-size:13px;line-height:1.7;padding-left:18px;margin:0">
      <li>Vérif. crédit : ${consents.credit ? '✅' : '❌'} · Employeur : ${consents.employer ? '✅' : '❌'} · Propriétaire : ${consents.landlord ? '✅' : '❌'} · Références : ${consents.references ? '✅' : '❌'}</li>
      <li>Évaluation automatisée : ${consents.automated ? '✅' : '❌'} · Déclaration véridique : ${consents.truthful ? '✅' : '❌'}</li>
    </ul>

    <div style="margin-top:32px;padding-top:16px;border-top:1px solid #d0cec8;font-size:11px;color:#888;line-height:1.6">
      <strong>Référence :</strong> ${candidatureId}<br>
      <strong>Loi 25 :</strong> Conservation 12 mois maximum, sauf candidature acceptée. Répondre au candidat avec le bouton « Répondre » — le reply-to pointe vers son courriel.
    </div>
  </div>
</div></body></html>`;
}

// ============================================================
// Notification fire-and-forget au gestionnaire de l'immeuble
// ============================================================
async function notifyManager(
  // deno-lint-ignore no-explicit-any
  supabase: any,
  candidatureId: string,
  buildingId: string | null,
  // deno-lint-ignore no-explicit-any
  formData: any,
  score: ScoreBreakdown,
  // deno-lint-ignore no-explicit-any
  consents: any,
): Promise<void> {
  if (!buildingId) {
    console.log("notifyManager: no building_id, skipping email");
    return;
  }
  const { data: building, error: buildingErr } = await supabase
    .from('building_registry')
    .select('name, notification_email')
    .eq('id', buildingId)
    .single();
  if (buildingErr || !building?.notification_email) {
    console.log("notifyManager: no notification_email for building", buildingId, buildingErr);
    return;
  }

  const html = buildEmailHtml(candidatureId, building.name, formData, score, consents);
  const subject = `Candidature ${building.name} — ${formData.first_name || ''} ${formData.last_name || ''} (${score.total}/100, ${score.category.replace('_', ' ')})`;

  const res = await fetch(`${SUPABASE_URL}/functions/v1/send-email`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${SUPABASE_SERVICE_KEY}`,
      'apikey': SUPABASE_SERVICE_KEY,
    },
    body: JSON.stringify({
      to: building.notification_email,
      subject,
      html,
      reply_to: formData.email || undefined,
    }),
  });

  if (!res.ok) {
    const errorText = await res.text();
    console.error("notifyManager: send-email failed", res.status, errorText);
  } else {
    console.log("notifyManager: email sent to", building.notification_email);
  }
}

// ============================================================
// HANDLER
// ============================================================
serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  try {
    const body = await req.json();
    const formData = body.form_data || {};

    if (!formData.email || !formData.last_name || !formData.first_name) {
      return new Response(JSON.stringify({ error: "Champs obligatoires manquants" }), {
        status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    if (!formData.consent_automated || !formData.declaration_truthful) {
      return new Response(JSON.stringify({ error: "Consentements obligatoires manquants" }), {
        status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const score = calculateScore(formData);

    const ip = req.headers.get("x-forwarded-for") ?? req.headers.get("cf-connecting-ip") ?? "";
    let ipHash: string | null = null;
    if (ip) {
      const enc = new TextEncoder().encode(ip);
      const hash = await crypto.subtle.digest("SHA-256", enc);
      ipHash = Array.from(new Uint8Array(hash)).map(b => b.toString(16).padStart(2, '0')).join('');
    }

    const consents = {
      credit:     bool(formData.consent_credit),
      employer:   bool(formData.consent_employer),
      landlord:   bool(formData.consent_landlord),
      references: bool(formData.consent_references),
      automated:  bool(formData.consent_automated),
      truthful:   bool(formData.declaration_truthful),
      consented_at: new Date().toISOString(),
    };

    const retentionUntil = new Date();
    retentionUntil.setMonth(retentionUntil.getMonth() + 12);

    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY, {
      auth: { persistSession: false },
    });

    const { data, error } = await supabase
      .from("candidatures")
      .insert({
        building_id:        body.building_id || null,
        form_data:          formData,
        score_total:        score.total,
        score_category:     score.category,
        score_breakdown:    score,
        score_computed_at:  new Date().toISOString(),
        consents,
        retention_until:    retentionUntil.toISOString(),
        user_agent:         body.user_agent || null,
        locale:             body.locale || null,
        ip_hash:            ipHash,
        status:             'recu',
      })
      .select("id")
      .single();

    if (error) {
      console.error("Insert error:", error);
      return new Response(JSON.stringify({ error: "Erreur d'enregistrement" }), {
        status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Notification fire-and-forget -- ne bloque pas la reponse au candidat
    notifyManager(supabase, data.id, body.building_id || null, formData, score, consents)
      .catch(err => console.error("notifyManager threw:", err));

    return new Response(JSON.stringify({
      success: true,
      candidature_id: data.id,
      message: "Votre candidature a ete recue.",
    }), {
      status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error("Handler error:", err);
    return new Response(JSON.stringify({ error: "Erreur interne" }), {
      status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
