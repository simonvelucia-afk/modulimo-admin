// Types partages du worker finance-sync. Aucune dependance Deno ici.

export interface BuildingToSync {
  building_id: string;
  supabase_url: string;
  last_synced_at: string | null;
  last_synced_tx_id: string | null;
}

export interface CohabitatTransaction {
  id: string;
  user_id: string;
  amount: string;                    // numeric arrivant en string
  type: string;
  reference_id: string | null;
  reference_type: string | null;
  description: string | null;
  created_at: string;
  created_by: string | null;
}

export interface SyncResult {
  building_id: string;
  applied: number;      // nouvelles tx ecrites sur central
  replayed: number;     // tx deja vues (idempotent replay)
  skipped: number;      // profiles sans row clients central
  errors: number;
  last_synced_tx_id: string | null;
  last_synced_at: string | null;
  error_message: string | null;
}
