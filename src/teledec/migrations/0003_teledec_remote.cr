# SPDX-License-Identifier: AGPL-3.0-or-later

# Adaptateur réel de TELEDEC : suivi d'un dépôt chez le partenaire (état
# brut, identifiant de la déclaration, référence envoyée, page à ouvrir par
# l'utilisateur) ; compte TELEDEC de l'entreprise (email), SIRET de
# l'établissement déclarant et jeton des rappels de TELEDEC (chiffré). Un
# même identifiant de déclaration ne désigne qu'un dépôt (rappels
# idempotents).
class Migration::Teledec::V0003 < Marten::Migration
  depends_on :teledec, "0002_teledec_foreign_keys"

  def plan
    add_column :teledec_filing, :remote_reference, :string, max_size: 128, default: "", index: true
    add_column :teledec_filing, :remote_status, :string, max_size: 32, default: ""
    add_column :teledec_filing, :remote_url, :text, default: ""
    add_column :teledec_filing, :declaration_id, :string, max_size: 64, default: "", index: true
    add_column :teledec_settings, :email, :string, max_size: 255, default: ""
    add_column :teledec_settings, :siret, :string, max_size: 14, default: ""
    add_column :teledec_settings, :callback_token, :text, default: ""
    execute(<<-SQL, "ALTER TABLE teledec_settings DROP CONSTRAINT IF EXISTS teledec_settings_siret_check")
      ALTER TABLE teledec_settings ADD CONSTRAINT teledec_settings_siret_check CHECK (siret = '' OR siret ~ '^[0-9]{14}$')
      SQL
  end
end
