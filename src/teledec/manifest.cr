# SPDX-License-Identifier: AGPL-3.0-or-later

# Manifeste de l'extension TELEDEC (ADR-003 D2, ADR-007 D4).
#
# * Dépendance : `ACCOUNTING` *ou* `LIBERAL` (`depends_on_any`, ADR-003 D2 ;
#   ADR-007 D4 amendé, DECISIONS D-TDC-002 et D-TDC2-001). Avec la
#   Comptabilité : toutes les déclarations (balance de l'exercice,
#   déclarations de TVA du lot 4, écritures de la DAS2, relevés d'IS), la
#   2035 joignant les cases du module `liberal` s'il est actif. Avec le
#   module `liberal` seul : la liasse 2035 seulement, construite à partir de
#   la 2035 qu'il prépare, sans balance (`Teledec::Sources`).
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
  depends_on_any "ACCOUNTING", "LIBERAL"

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
