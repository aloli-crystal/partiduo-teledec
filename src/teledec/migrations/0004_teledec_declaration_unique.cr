# SPDX-License-Identifier: AGPL-3.0-or-later

# Un même identifiant de déclaration de TELEDEC ne désigne qu'un dépôt
# (promesse de la migration 0003, que son index simple ne tenait pas) : les
# rappels retrouvent un dépôt par cet identifiant quand la référence manque.
# Index unique partiel, l'identifiant restant vide tant que TELEDEC ne l'a
# pas donné (DECISIONS D-TDC-023).
class Migration::Teledec::V0004 < Marten::Migration
  depends_on :teledec, "0003_teledec_remote"

  def plan
    execute(<<-SQL, "DROP INDEX IF EXISTS teledec_filing_declaration_id_key")
      CREATE UNIQUE INDEX teledec_filing_declaration_id_key ON teledec_filing (declaration_id) WHERE declaration_id <> ''
      SQL
  end
end
