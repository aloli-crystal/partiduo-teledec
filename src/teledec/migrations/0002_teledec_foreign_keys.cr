# SPDX-License-Identifier: AGPL-3.0-or-later

# Clés étrangères vers les tables du socle (ADR-006 D1, relecture du lot T) :
# exercice des dépôts (suppression de l'exercice refusée tant qu'un dépôt
# le cite : `delete_fiscal_year` rend alors `in_use`) et auteurs (préparation,
# transmission, paramètres, historique ; mis à NULL si l'utilisateur est
# supprimé, l'historique restant lisible).
class Migration::Teledec::V0002 < Marten::Migration
  depends_on :teledec, "0001_create_teledec"
  depends_on :auth, "0002_auth_security"

  CONSTRAINTS = [
    {<<-SQL, <<-SQL},
      ALTER TABLE teledec_filing
        ADD CONSTRAINT teledec_filing_fiscal_year_fk FOREIGN KEY (fiscal_year_id) REFERENCES core_fiscal_year (id),
        ADD CONSTRAINT teledec_filing_prepared_by_fk FOREIGN KEY (prepared_by_id) REFERENCES auth_user (id) ON DELETE SET NULL,
        ADD CONSTRAINT teledec_filing_transmitted_by_fk FOREIGN KEY (transmitted_by_id) REFERENCES auth_user (id) ON DELETE SET NULL
      SQL
      ALTER TABLE teledec_filing
        DROP CONSTRAINT IF EXISTS teledec_filing_fiscal_year_fk,
        DROP CONSTRAINT IF EXISTS teledec_filing_prepared_by_fk,
        DROP CONSTRAINT IF EXISTS teledec_filing_transmitted_by_fk
      SQL
    {<<-SQL, <<-SQL},
      ALTER TABLE teledec_filing_event
        ADD CONSTRAINT teledec_filing_event_user_fk FOREIGN KEY (user_id) REFERENCES auth_user (id) ON DELETE SET NULL
      SQL
      ALTER TABLE teledec_filing_event DROP CONSTRAINT IF EXISTS teledec_filing_event_user_fk
      SQL
    {<<-SQL, <<-SQL},
      ALTER TABLE teledec_settings
        ADD CONSTRAINT teledec_settings_updated_by_fk FOREIGN KEY (updated_by_id) REFERENCES auth_user (id) ON DELETE SET NULL
      SQL
      ALTER TABLE teledec_settings DROP CONSTRAINT IF EXISTS teledec_settings_updated_by_fk
      SQL
  ]

  def plan
    CONSTRAINTS.each { |(forward, backward)| execute(forward, backward) }
  end
end
