-- ============================================================
-- 025_leads_pointe_est.sql
-- Migration : table des leads Pointe Est (formulaire de contact
-- de modulimo.com — repo modulimo-home, js/lead-form.js).
-- Conforme Loi 25 (Québec)
-- ============================================================
-- À exécuter dans le SQL Editor du projet Central (bpxscgrbxjscicpnheep).
-- Idempotent : peut être rejoué sans danger.
-- Copie de référence : modulimo-home/supabase/leads_pointe_est.sql
--
-- RLS « option alpha » (pattern des migrations 013/023 de modulimo-admin) :
-- pas de table user_roles dans ce projet — tout utilisateur authentifié
-- (login modulimo-admin) est admin. La sécurité vient de qui peut se
-- connecter au projet. Aucune policy INSERT : les leads entrent
-- exclusivement par l'Edge Function submit-lead-pointe-est
-- (service_role, bypass RLS).

BEGIN;

-- 1. Table principale
create table if not exists public.leads_pointe_est (
  id          uuid primary key default gen_random_uuid(),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  -- Identité et message (renseignements personnels — Loi 25)
  first_name  text not null,
  last_name   text not null,
  email       text not null,
  message     text,

  -- Consentement explicite (récap horodaté, version du texte affiché)
  consent     jsonb not null,

  -- Suivi commercial
  status      text not null default 'nouveau'
    check (status in ('nouveau', 'contacte', 'converti', 'ferme')),
  admin_notes text,

  -- Métadonnées techniques (Loi 25 : hash de l'IP, jamais l'IP brute)
  locale      text,
  source_page text,
  user_agent  text,
  ip_hash     text,

  -- Date de destruction effective des renseignements personnels
  destroyed_at timestamptz
);

create index if not exists idx_leads_pe_created on public.leads_pointe_est(created_at desc);
create index if not exists idx_leads_pe_status  on public.leads_pointe_est(status);
create index if not exists idx_leads_pe_email   on public.leads_pointe_est(email);

-- 2. Trigger updated_at (réutilise la convention set_updated_at de 023)
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_leads_pe_updated on public.leads_pointe_est;
create trigger trg_leads_pe_updated
  before update on public.leads_pointe_est
  for each row execute function public.set_updated_at();

-- 3. RLS — option alpha (authenticated = admin)
alter table public.leads_pointe_est enable row level security;

-- INSERT : aucune policy — Edge Function uniquement (service_role).

drop policy if exists leads_pe_authenticated_select on public.leads_pointe_est;
create policy leads_pe_authenticated_select on public.leads_pointe_est
  for select to authenticated using (true);

drop policy if exists leads_pe_authenticated_update on public.leads_pointe_est;
create policy leads_pe_authenticated_update on public.leads_pointe_est
  for update to authenticated using (true) with check (true);

drop policy if exists leads_pe_authenticated_delete on public.leads_pointe_est;
create policy leads_pe_authenticated_delete on public.leads_pointe_est
  for delete to authenticated using (true);

grant select, update, delete on public.leads_pointe_est to authenticated;

-- 4. Destruction des renseignements personnels (droit de retrait — Loi 25)
-- SECURITY DEFINER pour bypasser RLS, garde-fou minimal auth.uid()
-- (modèle authenticated = admin, comme destroy_candidature_pii).
create or replace function public.destroy_lead_pointe_est_pii(p_lead_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = 'insufficient_privilege';
  end if;

  update public.leads_pointe_est
  set
    first_name   = '[détruit]',
    last_name    = '[détruit]',
    email        = '[détruit]',
    message      = null,
    consent      = jsonb_build_object('_destroyed', true),
    user_agent   = null,
    ip_hash      = null,
    destroyed_at = now()
  where id = p_lead_id;
end;
$$;

revoke all on function public.destroy_lead_pointe_est_pii(uuid) from public;
grant execute on function public.destroy_lead_pointe_est_pii(uuid) to authenticated;

comment on table public.leads_pointe_est is
  'Leads du formulaire de contact Pointe Est (modulimo.com). Conforme Loi 25 : consentement explicite horodaté, IP hashée, fonction de destruction des PII. Insertion via Edge Function submit-lead-pointe-est uniquement.';

COMMIT;
