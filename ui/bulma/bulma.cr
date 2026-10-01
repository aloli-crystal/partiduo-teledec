# SPDX-License-Identifier: AGPL-3.0-or-later

# Interface Bulma de l'extension TELEDEC (ADR-005 D4, ADR-007 D4) : écran
# « Télédéclarations » (échéances d'un exercice, préparation, contrôle,
# transmission, statut, accusés), fiche d'un dépôt, export de la balance
# en repli, paramètres. Montée par `partiduo-ui-bulma` sous `/ext/TELEDEC/`
# (ADR-003 D3). La distribution la requiert après l'interface :
#
# ```
# require "partiduo-ui-bulma/partiduo_ui"
# require "partiduo-teledec"
# require "partiduo-teledec/ui/bulma"
# ```
#
# puis ajoute `Teledec::Ui::INSTALLED_APPS` à ses applications Marten.
#
# Ce dossier ne parle au métier que par `Teledec::Api` et `Partiduo::Api`
# (vérifié par `spec/architecture/conventions_spec.cr`) ; le contrôle d'accès
# est fait par l'interface, avant le handler, à partir du manifeste.
require "../../src/partiduo-teledec"

require "./presenters"
require "./handlers/**"

module Teledec
  module Ui
    # Application Marten de l'interface Bulma de l'extension : gabarits
    # (`templates/teledec/`) et libellés d'écran (`locales/`, clés
    # `teledec_ui.*`).
    class App < Marten::App
      label "teledec_ui"
    end

    INSTALLED_APPS = [Teledec::Ui::App] of Marten::Apps::Config.class

    # Routes servies sous `/ext/TELEDEC/`, nommées `teledec:<nom>`.
    ROUTES = Marten::Routing::Map.draw do
      path "/", Teledec::Ui::IndexHandler, name: "index"
      path "/prepare", Teledec::Ui::PrepareHandler, name: "prepare"
      path "/refresh", Teledec::Ui::RefreshAllHandler, name: "refresh_all"
      path "/balance/<fiscal_year_id:int>", Teledec::Ui::BalanceHandler, name: "balance"
      path "/filings/<id:int>", Teledec::Ui::FilingHandler, name: "filing"
      path "/filings/<id:int>/check", Teledec::Ui::CheckHandler, name: "check"
      path "/filings/<id:int>/transmit", Teledec::Ui::TransmitHandler, name: "transmit"
      path "/filings/<id:int>/refresh", Teledec::Ui::RefreshHandler, name: "refresh"
      path "/filings/<id:int>/outcome", Teledec::Ui::OutcomeHandler, name: "outcome"
      path "/filings/<id:int>/export", Teledec::Ui::ExportHandler, name: "export"
      path "/filings/<id:int>/receipt", Teledec::Ui::ReceiptHandler, name: "receipt"
      path "/filings/<id:int>/document", Teledec::Ui::DocumentHandler, name: "document"
      path "/settings", Teledec::Ui::SettingsHandler, name: "settings"
      path "/settings/credentials", Teledec::Ui::CredentialsHandler, name: "credentials"
      path "/settings/credentials/clear", Teledec::Ui::ClearCredentialsHandler, name: "clear_credentials"
    end
  end
end

# Toutes les routes exigent au moins `teledec.return.read` ; le contrat
# vérifie ensuite la permission propre à chaque commande.
PartiduoUi::Extensions.mount Teledec::CODE, Teledec::Ui::ROUTES, permission: Teledec::Api::READ

# Rappels de TELEDEC (webhook) : appel de machine à machine, sans session,
# donc hors de `/ext/` (qui exige un utilisateur connecté) ; authentifié par
# le mot de passe des rappels du partenaire (`Teledec::Ui::CallbackHandler`).
Marten.routes.path Teledec::Api::CALLBACK_PATH, Teledec::Ui::CallbackHandler, name: "teledec_callback"
