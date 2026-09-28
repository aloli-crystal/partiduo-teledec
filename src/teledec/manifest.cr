# SPDX-License-Identifier: AGPL-3.0-or-later

# Manifeste de l'extension TELEDEC (ADR-003 D2, ADR-007 D4).
#
# * Dépendance : `ACCOUNTING` (la balance de l'exercice, les déclarations de
#   TVA du lot 4, les écritures de la DAS2). La 2035 préparée par le module
#   `liberal` est lue s'il est actif (DECISIONS D-TDC-002).
# * Permissions : `teledec.return.read` (voir les échéances, les dépôts et
#   les accusés), `teledec.return.prepare` (préparer et contrôler une
#   déclaration, exporter la balance), `teledec.return.transmit`
#   (transmettre à TELEDEC, noter un dépôt fait hors de Partiduo),
#   `teledec.settings.manage` (régime, options, identifiants de l'API).
# * Menus : « Télédéclarations » sous « TVA » (rubrique des déclarations) et
#   paramètres sous « Paramètres ».
# * Aucun abonnement : les déclarations sont préparées à la demande.
Partiduo::Modules.register do
  code "TELEDEC"
  name "teledec.module.name"
  version "0.1.0"
  requires_core "~> 0.1"
  depends_on "ACCOUNTING"

  permission "teledec.return.read"
  permission "teledec.return.prepare"
  permission "teledec.return.transmit"
  permission "teledec.settings.manage"

  menu "TELEDEC", parent: "VAT", order: 50, route: "teledec:index", permission: "teledec.return.read",
    label: "teledec.menu.returns"
  menu "TELEDEC_SETTINGS", parent: "SETTINGS", order: 92, route: "teledec:settings", permission: "teledec.settings.manage",
    label: "teledec.menu.settings"

  ui "bulma", path: "ui/bulma"
end
