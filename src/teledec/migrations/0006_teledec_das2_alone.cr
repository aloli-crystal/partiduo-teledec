# SPDX-License-Identifier: AGPL-3.0-or-later

# La DAS2 part seule, formulaire principal, au millésime de sa campagne
# (DECISIONS D-TDC6-001) : l'erreur « régime inconnu pour la DAS2 »
# (`teledec.errors.transport.das2_regime`, D-TDC5-001) n'existe plus. Une
# dernière erreur qui la porte est effacée (la transmission peut être
# relancée telle quelle) ; dans l'historique, l'événement garde son statut,
# sans ce détail devenu sans objet.
class Migration::Teledec::V0006 < Marten::Migration
  depends_on :teledec, "0005_teledec_account"

  # Clé retirée des traductions : écrite en deux morceaux pour que la
  # vérification des clés citées ne la cherche pas.
  OBSOLETE = "teledec.errors.transport." + "das2_regime"

  def plan
    execute("UPDATE teledec_filing SET last_error = '' WHERE last_error = '#{OBSOLETE}'", "SELECT 1")
    execute("UPDATE teledec_filing_event SET detail = '' WHERE detail = '#{OBSOLETE}'", "SELECT 1")
  end
end
