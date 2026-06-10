// ============================================================
// MODULIMO — Edge Function : submit-lead-pointe-est
// ============================================================
// Reçoit le formulaire « Informez-vous » du site modulimo.com :
//   1. insère le lead dans la table public.leads_pointe_est
//   2. envoie une notification courriel via Resend
//
// Secrets requis (déjà configurés côté Supabase pour send-email) :
//   RESEND_KEY        — clé API Resend (ne JAMAIS la mettre dans le repo)
//   RESEND_FROM       — ex. 'Modulimo <no-reply@modulimo.com>' (optionnel)
//   LEADS_NOTIFY_TO   — destinataire des notifications
//                       (optionnel, défaut : contribution@modulimo.com)
//
// Déploiement (projet Central) :
//   supabase functions deploy submit-lead-pointe-est --project-ref bpxscgrbxjscicpnheep
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RESEND_KEY = Deno.env.get("RESEND_KEY") ?? "";
const RESEND_FROM = Deno.env.get("RESEND_FROM") ?? "Modulimo <no-reply@modulimo.com>";
const NOTIFY_TO = Deno.env.get("LEADS_NOTIFY_TO") ?? "contribution@modulimo.com";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
  "Access-Control-Max-Age": "86400",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "content-type": "application/json" },
  });
}

function esc(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[c] as string));
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS_HEADERS });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Corps JSON invalide" }, 400);
  }

  // Honeypot anti-spam : si le champ caché est rempli, on répond
  // « succès » sans rien enregistrer (ne pas renseigner les bots).
  if (typeof body.website === "string" && body.website.trim() !== "") {
    return json({ ok: true });
  }

  const firstName = String(body.first_name ?? "").trim().slice(0, 120);
  const lastName = String(body.last_name ?? "").trim().slice(0, 120);
  const email = String(body.email ?? "").trim().slice(0, 254);
  const message = String(body.message ?? "").trim().slice(0, 4000);
  const locale = String(body.locale ?? "").trim().slice(0, 16) || null;
  const sourcePage = String(body.source_page ?? "").trim().slice(0, 200) || null;

  if (!firstName || !lastName) return json({ error: "missing_name" }, 400);
  if (!EMAIL_RE.test(email)) return json({ error: "invalid_email" }, 400);
  if (body.consent !== true) return json({ error: "missing_consent" }, 400);

  // Loi 25 : hash de l'IP, jamais l'IP brute
  const ip = req.headers.get("x-forwarded-for")?.split(",")[0].trim() ?? "";
  let ipHash: string | null = null;
  if (ip) {
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(ip));
    ipHash = Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY, {
    auth: { persistSession: false },
  });

  const { data, error } = await supabase
    .from("leads_pointe_est")
    .insert({
      first_name: firstName,
      last_name: lastName,
      email,
      message: message || null,
      consent: {
        marketing_contact: true,
        text_version: body.consent_text_version ?? "2026-06-v1",
        consented_at: new Date().toISOString(),
      },
      locale,
      source_page: sourcePage,
      user_agent: String(body.user_agent ?? "").slice(0, 500) || null,
      ip_hash: ipHash,
      status: "nouveau",
    })
    .select("id")
    .single();

  if (error) {
    console.error("[submit-lead-pointe-est] insert error:", error);
    return json({ error: "storage_error" }, 500);
  }

  // Notification courriel — un échec d'envoi ne doit pas faire échouer
  // la requête : le lead est déjà enregistré.
  if (RESEND_KEY) {
    try {
      const res = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${RESEND_KEY}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          from: RESEND_FROM,
          to: [NOTIFY_TO],
          reply_to: email,
          subject: `Nouveau lead Pointe Est — ${firstName} ${lastName}`,
          html: [
            `<h2>Nouveau lead — Pointe Est</h2>`,
            `<p><strong>Nom :</strong> ${esc(firstName)} ${esc(lastName)}</p>`,
            `<p><strong>Courriel :</strong> ${esc(email)}</p>`,
            message ? `<p><strong>Message :</strong><br>${esc(message).replace(/\n/g, "<br>")}</p>` : "",
            `<p style="color:#888;font-size:12px">Langue : ${esc(locale ?? "—")} · Page : ${esc(sourcePage ?? "—")} · ID : ${data.id}</p>`,
          ].join("\n"),
        }),
      });
      if (!res.ok) console.error("[submit-lead-pointe-est] resend error:", res.status, await res.text());
    } catch (e) {
      console.error("[submit-lead-pointe-est] resend exception:", e);
    }
  } else {
    console.warn("[submit-lead-pointe-est] RESEND_KEY absent — notification non envoyée");
  }

  return json({ ok: true, lead_id: data.id });
});
