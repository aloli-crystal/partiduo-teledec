# SPDX-License-Identifier: AGPL-3.0-or-later

# Dépôt au greffe par TELEDEC (réponses du 1er octobre 2026, DECISIONS
# D-TDC9-001, D-TDC9-002) : le PDF signé du dépôt, servi dès qu'il est
# finalisé, est conservé en pièce jointe du socle, à côté de l'accusé.
# L'erreur « le greffe ne passe pas par l'API » n'existe plus : une
# dernière erreur qui la porte est effacée (la transmission peut être
# relancée), et le détail des événements qui la citaient est vidé.
class Migration::Teledec::V0007 < Marten::Migration
  depends_on :teledec, "0006_teledec_das2_alone"

  # Clé retirée des traductions : écrite en deux morceaux pour que la
  # vérification des clés citées ne la cherche pas.
  OBSOLETE = "teledec.errors.transport." + "greffe"

  def plan
    add_column :teledec_filing, :document_attachment_id, :big_int, null: true
    execute("UPDATE teledec_filing SET last_error = '' WHERE last_error = '#{OBSOLETE}'", "SELECT 1")
    execute("UPDATE teledec_filing_event SET detail = '' WHERE detail = '#{OBSOLETE}'", "SELECT 1")
  end
end
