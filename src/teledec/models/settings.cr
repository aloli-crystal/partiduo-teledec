# SPDX-License-Identifier: AGPL-3.0-or-later

module Teledec
  # Paramètres de l'extension (ligne unique, `key = "default"`) : régime
  # d'imposition (formulaires de la liasse), régime de TVA, option du dépôt
  # des comptes au greffe, comptes et seuil de la DAS2, identifiants de
  # l'API TELEDEC *chiffrés* (`Teledec::Secrets`, ADR-007 D4). Interne.
  class Settings < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :key, :string, max_size: 16, unique: true, default: "default"
    field :tax_system, :string, max_size: 16, blank: true, default: ""
    field :vat_system, :string, max_size: 16, blank: true, default: ""
    field :greffe, :bool, default: false
    # JSON `{"6226": "fees", …}` : préfixe de compte → nature de la DAS2.
    field :das2_accounts, :text, blank: true, default: ""
    field :das2_threshold, :decimal, max_digits: 20, decimal_places: 2, default: Teledec::Config::DAS2_THRESHOLD
    field :env, :string, max_size: 16, default: "sandbox"
    field :login, :string, max_size: 255, blank: true, default: ""
    # `v1:<base64>` : clé de l'API chiffrée ; vide si aucune.
    field :api_key, :text, blank: true, default: ""
    field :checked_at, :date_time, blank: true, null: true
    field :updated_by_id, :big_int, blank: true, null: true

    with_timestamp_fields

    def self.current : Settings?
      filter(key: "default").first
    end

    def self.current! : Settings
      current || new(key: "default")
    end
  end
end
