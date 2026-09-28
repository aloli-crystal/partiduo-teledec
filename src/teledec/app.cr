# SPDX-License-Identifier: AGPL-3.0-or-later

require "./manifest"
require "./config"
require "./money"
require "./secrets"
require "./transport"
require "./payload"
require "./models/**"
require "./services/**"
require "./api/**"

# Extension TELEDEC de Partiduo (ADR-007 D4, D5) : télédéclarations fiscales
# par le partenaire EDI TELEDEC, formule *API Balance* — Partiduo transmet la
# balance de l'exercice et l'identité de l'entreprise, TELEDEC remplit les
# formulaires. Même plan qu'une application du cœur (DECISIONS C1) :
# `manifest.cr`, `models/`, `migrations/`, `services/` (interne), `api/`
# (contrat public `Teledec::Api`), `locales/` ; en plus `transport.cr`
# (interface abstraite `Teledec::Transport`), `payload.cr` (document
# transmis), `secrets.cr` (identifiants chiffrés) et `money.cr` (arrondis).
module Teledec
  VERSION = "0.1.0"

  # Code du registre (ADR-003 D2) : `teledec` dans `PARTIDUO_MODULES`.
  CODE = "TELEDEC"

  # Application Marten du métier : modèles (tables `teledec_*`), migrations
  # et libellés.
  class App < Marten::App
    label "teledec"
  end

  # Applications Marten du métier, à ajouter à `installed_apps` de la
  # distribution après `Partiduo::INSTALLED_APPS`.
  INSTALLED_APPS = [Teledec::App] of Marten::Apps::Config.class
end
