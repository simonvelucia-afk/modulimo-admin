-- =====================================================================
-- 029_candidatures_acces_immeuble.sql
-- Ferme l'accès public aux candidatures.
-- =====================================================================
-- 024 exposait list_candidatures_for_building et
-- decide_candidature_for_building au rôle anon, avec pour seule garde le
-- building_id passé en paramètre. Or ce building_id figure en clair dans
-- la page publique /postuler/ de modulimo.com, et la clé anon centrale
-- est publique : n'importe qui pouvait lire les candidatures d'un
-- immeuble (nom, courriel, revenu, réponses au formulaire) et les
-- accepter ou les refuser.
--
-- Après ce fichier :
--   * les deux fonctions ne sont plus exécutables que par service_role ;
--   * l'admin d'un immeuble y accède par finance-bridge
--     (/candidatures-list et /candidatures-decide), qui vérifie son
--     jeton CoHabitat et son rôle d'admin, et impose lui-même le
--     building_id tiré du jeton vérifié — jamais celui du navigateur ;
--   * Modulimo Admin continue de lire la table directement, avec sa
--     propre connexion (inchangé).
--
-- Corrige aussi l'erreur « Security Definer View » du Security Advisor :
-- candidatures_analytics s'exécutait avec les droits de son créateur et
-- contournait donc les règles d'accès de la table.
--
-- Idempotent. À exécuter dans le SQL Editor du projet Central.
-- =====================================================================

BEGIN;

-- 1. Fonctions des immeubles : plus d'accès anonyme ------------------
REVOKE EXECUTE ON FUNCTION public.list_candidatures_for_building(uuid)
  FROM anon, authenticated, public;
REVOKE EXECUTE ON FUNCTION public.decide_candidature_for_building(uuid, text, uuid)
  FROM anon, authenticated, public;

GRANT EXECUTE ON FUNCTION public.list_candidatures_for_building(uuid)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.decide_candidature_for_building(uuid, text, uuid)
  TO service_role;

COMMENT ON FUNCTION public.list_candidatures_for_building(uuid) IS
  'Liste les candidatures (non détruites) d''un immeuble. Réservée à service_role : appelée par finance-bridge /candidatures-list après vérification du jeton et du rôle admin de l''appelant (sql/029).';
COMMENT ON FUNCTION public.decide_candidature_for_building(uuid, text, uuid) IS
  'Décide une candidature d''un immeuble. Réservée à service_role : appelée par finance-bridge /candidatures-decide après vérification du jeton et du rôle admin de l''appelant (sql/029).';

-- 2. Vue d'analyse : respecte les règles d'accès de la table ---------
-- security_invoker : la vue s'exécute avec les droits de celui qui la
-- lit. Les utilisateurs connectés de Modulimo Admin la lisent comme
-- avant (la table les y autorise) ; un appel anonyme n'obtient rien.
ALTER VIEW public.candidatures_analytics SET (security_invoker = true);
REVOKE ALL ON public.candidatures_analytics FROM anon;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Vérification : anon ne doit plus figurer pour ces trois objets.
SELECT p.proname AS objet, r.rolname AS role_autorise
  FROM pg_proc p
  CROSS JOIN LATERAL aclexplode(p.proacl) a
  JOIN pg_roles r ON r.oid = a.grantee
 WHERE p.proname IN ('list_candidatures_for_building', 'decide_candidature_for_building')
UNION ALL
SELECT 'candidatures_analytics', grantee::text
  FROM information_schema.role_table_grants
 WHERE table_name = 'candidatures_analytics' AND privilege_type = 'SELECT'
 ORDER BY 1, 2;
