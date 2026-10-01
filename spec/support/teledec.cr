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

    # Clé de suivi TELEDEC de la liasse 2026 du dossier des specs.
    LIASSE_ID = "liasse:732829320:2026-12-31"

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

    # Droits d'un préparateur de la 2035 sans la Comptabilité.
    LIBERAL = [Api::READ, Api::PREPARE, Api::TRANSMIT, Api::SETTINGS, "liberal.register.read"]

    # Libéral : dossier français, exercice 2026, administrateur, module
    # `liberal` paramétré (kinésithérapeute), TELEDEC actif ; la
    # Comptabilité (active par `PARTIDUO_MODULES` pour provisionner le
    # dossier) est désactivée ensuite sauf `accounting: true`. Régime
    # d'imposition non choisi.
    def self.liberal_books(accounting : Bool = false, year : Int32 = 2026) : Nil
      PartiduoUi::Reference.provision("fr")
      @@fiscal_year_id = PartiduoUi::Reference.fiscal_year(year).id
      @@admin_id = PartiduoUi::Accounts.create.user.id
      Partiduo::Api::Modules.activate(SYSTEM, "LIBERAL").value!
      Partiduo::Api::Liberal.load_defaults(SYSTEM)
      Partiduo::Api::Liberal.update_settings(SYSTEM, Partiduo::Api::Liberal::SettingsInput.new(
        profession: "Masseur-kinésithérapeute", default_nature_id: liberal_nature("RECEIPTS").id)).value!
      Partiduo::Api::Modules.activate(SYSTEM, CODE).value!
      Partiduo::Api::Modules.deactivate(SYSTEM, "ACCOUNTING").value! unless accounting
      nil
    end

    def self.liberal_nature(code : String) : Partiduo::Api::Liberal::NatureView
      Partiduo::Api::Liberal.natures(SYSTEM).find(&.code.==(code)) || raise "nature #{code} absente"
    end

    # Corps de la 2035 d'un libéral sans Comptabilité, sans balance, tel que
    # l'adaptateur réel l'envoie à `/service/liasse` : construite comme la
    # suite du stage (module `liberal` seul, exercice `year`, livre-journal
    # d'un kinésithérapeute), préparée puis transmise (D-TDC7-001).
    def self.liberal_2035_body(year : Int32 = 2025) : String
      liberal_books(year: year)
      connect
      liberal_line("receipt", "#{year}-03-03", "42000", "RECEIPTS")
      liberal_line("expense", "#{year}-03-04", "9600", "RENT")
      liberal_line("expense", "#{year}-03-05", "850", "OFFICE")
      # La 2035 se transmet sur un exercice clôturé (D-LIB5-003).
      Partiduo::Api::Liberal.close_year(SYSTEM, year).value!
      actor = admin(LIBERAL)
      filing = Api.prepare(actor, Api::PrepareInput.new(kind: "liasse", fiscal_year_id: fiscal_year_id)).value!
      raise "2035 non prête : #{filing.controls.select(&.error?).map(&.key).join(", ")}" unless filing.ready?
      Api.transmit(actor, filing.id).value!
      teledec.requests.find! { |request| request.path == "/service/liasse" }.body
    end

    # Ligne du livre-journal de `liberal` (recette ou dépense).
    def self.liberal_line(kind : String, day : String, amount : String, nature : String) : Nil
      input = Partiduo::Api::Liberal::LineInput.new(date: Time.parse_utc(day, "%Y-%m-%d"),
        nature_id: liberal_nature(nature).id, amount: BigDecimal.new(amount), method: "transfer",
        party_name: "Patient", label: nature.downcase)
      result = if kind == "receipt"
                 Partiduo::Api::Liberal.record_receipt(SYSTEM, input)
               else
                 Partiduo::Api::Liberal.record_expense(SYSTEM, input)
               end
      raise "ligne refusée : #{result.errors.map(&.key).join(", ")}" if result.failure?
      nil
    end

    # En-tête `Authorization` d'un rappel de TELEDEC : mot de passe des
    # rappels du partenaire (réglage de l'instance, D-TDC3-006).
    def self.callback_authorization(password : String = ENV["PARTIDUO_TELEDEC_CALLBACK_PASSWORD"]) : String
      "Basic #{Base64.strict_encode("teledec:#{password}")}"
    end

    def self.connect : Nil
      Api.save_credentials(SYSTEM, Api::CredentialsInput.new(SimulatedTeledec::LOGIN, SimulatedTeledec::API_KEY,
        email: SimulatedTeledec::EMAIL, siret: SimulatedTeledec::SIRET)).value!
      nil
    end

    def self.supplier(name : String, siret : String? = SIRET, address : Bool = true, **person) : String
      category = PartiduoUi::Reference.category("SUPPLIER")
      input = Partiduo::Api::Cards::CardInput.new(category_id: category.id, name: name, siret: siret,
        description: "Avocat",
        address: address ? Partiduo::Api::Cards::AddressInput.new(line1: "3 rue des Lilas", postcode: "69003", city: "Lyon", country_code: "FR") : nil)
        .copy_with(**person)
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
