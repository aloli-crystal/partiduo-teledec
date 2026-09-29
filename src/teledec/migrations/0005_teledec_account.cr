# SPDX-License-Identifier: AGPL-3.0-or-later

# Réponses de TELEDEC du 29 septembre 2026 (DECISIONS D-TDC3-006, D-TDC3-007) :
# compte de l'entreprise en marque blanche (haché bcrypt du mot de passe,
# environnement où il a été créé) ; les rappels s'authentifient par un mot
# de passe du partenaire réglé dans l'instance : l'ancien jeton par
# entreprise est vidé.
class Migration::Teledec::V0005 < Marten::Migration
  depends_on :teledec, "0004_teledec_declaration_unique"

  def plan
    add_column :teledec_settings, :account_password_hash, :text, default: ""
    add_column :teledec_settings, :account_env, :string, max_size: 16, default: ""
    execute("UPDATE teledec_settings SET callback_token = ''", "SELECT 1")
  end
end
