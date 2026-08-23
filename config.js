/* ============================================================
 * Modulimo Admin — configuration runtime
 * ============================================================
 * Porte toutes les valeurs qui changent d'un deploiement a
 * l'autre : URL de la centrale, cle publique, emplacement des
 * librairies tierces.
 *
 * Les valeurs par defaut sont celles du deploiement heberge :
 * un checkout sans configuration se comporte comme avant.
 *
 * En mode APPLIANCE (deploy/), le serveur sert son propre
 * config.js genere a partir du .env — ce fichier est alors
 * remplace, pas modifie.
 * ============================================================ */
(function (global) {
  'use strict';

  var DEFAULTS = {
    instance: { id: 'modulimo-central', name: 'Modulimo Central' },

    // Base de la centrale (Supabase heberge ou appliance).
    centralUrl: 'https://bpxscgrbxjscicpnheep.supabase.co',
    centralKey: 'sb_publishable_2V-eHOvw1v_Xwr1bpHfHLg_cbHW9ctD',

    // Adresse publique de l'interface d'administration.
    siteUrl: 'https://admin.modulimo.com',

    assets: {
      supabaseJs: 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2',
      favicon:    'https://simonvelucia-afk.github.io/modulimo-home/images/favicon_Modulimo.png'
    }
  };

  function merge(base, over) {
    var out = {}, k;
    for (k in base) if (Object.prototype.hasOwnProperty.call(base, k)) out[k] = base[k];
    if (!over) return out;
    for (k in over) {
      if (!Object.prototype.hasOwnProperty.call(over, k)) continue;
      var b = out[k], o = over[k];
      out[k] = (b && o && typeof b === 'object' && typeof o === 'object' &&
                !Array.isArray(b) && !Array.isArray(o)) ? merge(b, o) : o;
    }
    return out;
  }

  var cfg = merge(DEFAULTS, global.MODULIMO_CONFIG || {});

  // document.write preserve l'ordre synchrone : supabase-js doit exister
  // avant le script principal de la page.
  cfg.writeHeadAssets = function () {
    var a = cfg.assets, out = '';
    if (a.favicon)    out += '<link rel="icon" type="image/png" href="' + a.favicon + '">';
    if (a.supabaseJs) out += '<scr' + 'ipt src="' + a.supabaseJs + '"></scr' + 'ipt>';
    if (out) document.write(out);
  };

  global.ModulimoConfig = cfg;
})(window);
