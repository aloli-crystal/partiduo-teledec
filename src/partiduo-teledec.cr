# SPDX-License-Identifier: AGPL-3.0-or-later

# Point d'entrée du shard `partiduo-teledec` : le métier de l'extension
# TELEDEC (manifeste, déclarations, suivi des dépôts, transport abstrait,
# contrat `Teledec::Api`), sans interface. L'interface Bulma est dans
# `ui/bulma/`, requise à part par la distribution :
# `require "partiduo-teledec/ui/bulma"`.
#
# La distribution ajoute ensuite `Teledec::INSTALLED_APPS` à ses
# applications Marten, et `require "partiduo-teledec/cli"` à sa ligne de
# commande (migrations).
require "partiduo"

require "./teledec/app"
