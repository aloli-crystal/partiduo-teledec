# SPDX-License-Identifier: AGPL-3.0-or-later

module Teledec
  module SpecSupport
    alias Api = Teledec::Api
    alias Acc = Partiduo::Api::Accounting
    alias Books = PartiduoUi::Books

    SYSTEM = Partiduo::Api::Actor.system
    SIRET  = "40483304800006"
    ALL    = [Api::READ, Api::PREPARE, Api::TRANSMIT, Api::SETTINGS, "accounting.report.read", "accounting.vat.declare"]
    @@admin_id = 1_i64
    @@fiscal_year_id = 0_i64

    def self.teledec : SimulatedTeledec
      Transports.current.as(SimulatedTeledec)
    end

    def self.admin(permissions : Array(String) = ALL) : Partiduo::Api::Actor
      Partiduo::Api::Actor.user(@@admin_id, permissions, level: 3)
    end

    def self.fiscal_year_id : Int64
      @@fiscal_year_id
    end

    # Dossier français, exercice 2026, administrateur, TELEDEC actif ;
    # régime IS simplifié et CA3 mensuelle par défaut.
    def self.books(tax_system : String = "is_rsi", vat_system : String = "ca3_monthly", greffe : Bool = false) : Nil
      PartiduoUi::Reference.provision("fr")
      @@fiscal_year_id = PartiduoUi::Reference.fiscal_year(2026).id
      @@admin_id = PartiduoUi::Accounts.create.user.id
      Partiduo::Api::Modules.activate(SYSTEM, CODE).value!
      %w[6226 6222].each do |number|
        Acc.create_account(SYSTEM, Acc::AccountInput.new(number: number, label: "Honoraires #{number}", parent: "62")).value!
      end
      Api.update_settings(SYSTEM, Api::SettingsInput.new(tax_system, vat_system, greffe)).value!
      nil
    end

    def self.connect : Nil
      Api.save_credentials(SYSTEM, Api::CredentialsInput.new(SimulatedTeledec::LOGIN, SimulatedTeledec::API_KEY)).value!
      nil
    end

    def self.supplier(name : String, siret : String? = SIRET, address : Bool = true) : String
      category = PartiduoUi::Reference.category("SUPPLIER")
      input = Partiduo::Api::Cards::CardInput.new(category_id: category.id, name: name, siret: siret,
        description: "Avocat",
        address: address ? Partiduo::Api::Cards::AddressInput.new(line1: "3 rue des Lilas", postcode: "69003", city: "Lyon", country_code: "FR") : nil)
      Partiduo::Api::Cards.create_card(SYSTEM, input).value!.code
    end

    # Facture d'honoraires de `amount` HT (TVA normale) du fournisseur.
    def self.fees(code : String, amount : String, day : String = "2026-04-10", account : String = "6226") : Acc::EntryView
      input = Acc::DocumentInput.new(ledger_id: Books.ledger("A01").id, date: Books.date(day), third_party: code,
        lines: [Acc::DocumentLineInput.new(amount: Books.d(amount), account: account, vat_rate: "NOR")], label: "Honoraires")
      Acc.post_purchase(SYSTEM, input).value!
    end

    def self.prepare(kind : String, **options) : Api::FilingView
      Api.prepare(admin, Api::PrepareInput.new(**options.merge(kind: kind))).value!
    end

    def self.liasse : Api::FilingView
      prepare("liasse", fiscal_year_id: fiscal_year_id)
    end
  end
end

# Chaque exemple part d'un TELEDEC simulé vierge.
Spec.before_each do
  Teledec::Transports.current = Teledec::SimulatedTeledec.new
end
