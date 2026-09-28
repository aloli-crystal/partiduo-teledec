# SPDX-License-Identifier: AGPL-3.0-or-later

# Vérification de bout en bout des lots G, L et T sur des instances
# provisionnées par `bin/partiduo-provision`, par l'interface servie sur un
# vrai port local (serveur de Marten démarré dans ce processus), avec
# TELEDEC simulé (accusé de réception de la DGFiP à la première relève).
#
# `--profile` :
#
# * `micro` (`--modules micro,invoicing,accounting`) : facture simplifiée
#   (mention 293 B) → encaissée par lettrage → recette au livre, écritures
#   générées ; recette directe → écriture de trésorerie ; montants URSSAF ;
#   alerte de seuil ;
# * `reel` (`--modules accounting,invoicing --with teledec`) : vente, achat
#   d'honoraires, CA3 close, liasse, CA3 et DAS2 transmises au TELEDEC
#   simulé, accusés ;
# * `liberal` (`--modules liberal,accounting --with teledec`) : recettes et
#   dépenses ventilées par rubrique, immobilisation amortie, 2035 préparée
#   puis transmise au TELEDEC simulé, accusé.
#
# `--keep` laisse le serveur ouvert pour un essai dans un navigateur.
ENV["MARTEN_ENV"] ||= "development"

require "option_parser"
require "partiduo-ui-bulma/partiduo_ui"
require "../src/partiduo-teledec"
require "../ui/bulma/bulma"
require "../config/settings/base"
require "../config/settings/**"
require "../spec/support/simulated_teledec"
require "./verif/browser"

module VerifT
  alias Inv = Partiduo::Api::Invoicing
  alias Acc = Partiduo::Api::Accounting
  alias Cards = Partiduo::Api::Cards
  alias Mic = Partiduo::Api::Micro
  alias Lib = Partiduo::Api::Liberal
  alias TApi = Teledec::Api

  # TELEDEC simulé qui accuse réception de chaque dépôt à la première
  # relève de son état, comme la DGFiP le fait après quelques minutes.
  class AutoAckTeledec < Teledec::SimulatedTeledec
    def status(credentials : Teledec::Credentials, remote_id : String) : Teledec::RemoteStatus
      acknowledge(remote_id) unless states.has_key?(remote_id)
      super
    end
  end

  class Run
    include Verif::Steps

    @actor : Partiduo::Api::Actor? = nil

    def initialize(@profile : String, @host : String, @port : Int32, @email : String, @password : String,
                   @invitation : String?)
    end

    def system : Partiduo::Api::Actor
      Partiduo::Api::Actor.system
    end

    def actor : Partiduo::Api::Actor
      @actor ||= Partiduo::Api::Auth.actor(Partiduo::Api::Auth.login_password(Partiduo::Api::Actor.anonymous,
        Partiduo::Api::Auth::PasswordLoginInput.new(@email, @password)).value!.session_token!)
    end

    def d(text : String) : BigDecimal
      BigDecimal.new(text)
    end

    def today : Time
      Partiduo::Api::Core.today
    end

    def year : Int32
      today.year
    end

    def run : Nil
      settings = Partiduo::Api::Core.settings(system)
      puts "== Instance #{@host} : « #{settings.company_name} », SIREN #{settings.siren}, modules actifs " \
           "#{Partiduo::Modules::State.active_codes.to_a.sort!.join(", ")} ; profil #{@profile} ; serveur http://#{@host}:#{@port}/"
      Teledec::Transports.current = AutoAckTeledec.new
      browser = Verif::Browser.new(@host, @port)
      login(browser)
      fiscal_year(browser) if Partiduo::Modules.active?("ACCOUNTING")
      case @profile
      when "micro"   then micro(browser)
      when "reel"    then reel(browser)
      when "liberal" then liberal(browser)
      else                raise "--profile inconnu : #{@profile}"
      end
    end

    # --- Connexion et exercice ------------------------------------------------------

    private def login(browser : Verif::Browser) : Nil
      section "Enrôlement et connexion"
      if invitation = @invitation
        path = "/invitation/#{invitation.split("/invitation/").last}"
        check("invitation acceptée") { redirect?(browser.submit(path, {} of String => String), "/account/enrollment") }
        check("mot de passe choisi à l'enrôlement") do
          browser.get("/account/enrollment")
          redirect?(browser.post("/account/enrollment", {"new_password" => @password, "confirmation" => @password}), "/login")
        end
      end
      check("connexion par mot de passe") { redirect?(browser.submit("/login", {"email" => @email, "password" => @password})) }
      check("tableau de bord") { expect(browser.get("/"), 200, Partiduo::Api::Core.settings(system).company_name) }
    end

    private def fiscal_year(browser : Verif::Browser) : Nil
      return if Partiduo::Api::Core.fiscal_years(system).any?(&.year.==(year))
      check("exercice #{year} créé") do
        redirect?(browser.submit("/fiscal-years", {"year" => year.to_s, "start_year" => year.to_s, "start_month" => "1",
                                                   "months" => "12", "label" => ""}), "/fiscal-years")
      end
    end

    private def fiscal_year_id : Int64
      Partiduo::Api::Core.fiscal_years(system).find! { |item| item.year == year }.id
    end

    private def card(browser : Verif::Browser, category_code : String, code : String, values : Hash(String, String)) : Nil
      return if Cards.card_by_code(system, code)
      category = Cards.category_by_code(system, category_code) || raise "catégorie #{category_code} absente"
      check("fiche #{code} créée (#{values["name"]})") do
        data = {"category_id" => category.id.to_s, "code" => code, "enabled" => "1"}.merge(values)
        redirect?(browser.submit("/cards/new?category=#{category.id}", data, "/cards/new"), "/cards/")
      end
    end

    private def entry_lines(entry : Acc::EntryView) : String
      entry.lines.map { |line| "#{line.account_number} #{line.side.debit? ? "D" : "C"} #{line.amount}" }.join(" ; ")
    end

    # Encaissement en banque de `amount` pour le tiers `code`, lettré avec la
    # ligne `customer_line` depuis l'écran de lettrage.
    private def bank_and_match(browser : Verif::Browser, code : String, amount : BigDecimal, label : String,
                               customer_line : Int64) : Nil
      bank = Acc.ledger_by_code(actor, "F01")
      check("encaissement de #{amount} € saisi en banque (#{bank.code})") do
        browser.get("/accounting/entries/financial")
        redirect?(browser.post("/accounting/entries/financial", {"ledger_id" => bank.id.to_s, "date" => today.to_s("%d/%m/%Y"),
                                                                 "line-0-account" => code, "line-0-label" => label,
                                                                 "line-0-debit" => amount.to_s.sub('.', ',')}), "/accounting/entries/financial")
      end
      check("lettrage de la facture et de l'encaissement depuis l'écran de lettrage") do
        page = browser.get("/accounting/matching?#{URI::Params.encode({"q" => code})}")
        ids = page.body.scan(/name="line" value="(\d+)"/).map(&.[1].to_i64)
        next "ligne de la facture absente" unless ids.includes?(customer_line)
        other = ids.find(&.!=(customer_line)) || next "ligne de l'encaissement absente"
        redirect?(browser.post_pairs("/accounting/matching", [{"q", code}, {"line", customer_line.to_s}, {"line", other.to_s}]))
      end
    end

    # --- Micro-entreprise ------------------------------------------------------------

    private def micro_nature(code : String) : Mic::NatureView
      Mic.natures(system).find { |nature| nature.code == code } || raise "nature #{code} absente"
    end

    # ameba:disable Metrics/CyclomaticComplexity
    private def micro(browser : Verif::Browser) : Nil
      section "Paramètres de la micro-entreprise"
      check("tableau de bord simplifié (micro-entreprise)") { expect(browser.get("/"), 200, "pd-simple") }
      check("paramètres : déclaration trimestrielle, activité commencée le 1er janvier") do
        redirect?(browser.submit("/micro/settings", {"periodicity" => "quarterly", "activity_started_on" => "#{year}-01-01",
                                                     "default_nature_id" => micro_nature("SERVICE").id.to_s}), "/")
      end

      section "Facture simplifiée (franchise en base, 293 B) → encaissée → recette au livre"
      invoice_id = nil
      check("facture en quelques champs : client nouveau, mention 293 B d'office") do
        form = browser.get("/micro/invoices/new")
        next expect(form, 200) unless form.status_code == 200
        next "mention 293 B absente du formulaire" unless text_of(form).includes?("293 B")
        response = browser.post("/micro/invoices/new", {"customer_name" => "Atelier Morel", "line-0-description" => "Réparation de vélo",
                                                        "line-0-quantity" => "3", "line-0-price" => "85", "due_date" => ""})
        next redirect?(response, "/invoicing/documents/") unless response.status_code == 302
        invoice_id = response.headers["Location"].split('/').last.to_i64
        true
      end
      id = invoice_id || return
      check("facture validée : numéro, total 255,00 sans TVA, mention « TVA non applicable, art. 293 B du CGI »") do
        response = browser.post("/invoicing/documents/#{id}/issue")
        next redirect?(response) unless response.status_code == 302
        view = Inv.document(actor, id)
        next "sans numéro#{danger(browser.follow(response))}" unless view.number
        next "TVA #{view.totals.total_vat}" unless view.totals.total_vat.zero? && view.totals.total_gross == d("255")
        note "#{view.number} : #{view.totals.total_gross} €, mentions #{view.mentions.map(&.code).join(", ")}"
        expect(browser.get("/invoicing/documents/#{id}/preview"), 200, "293 B")
      end
      sale = nil
      check("écriture de vente générée par la Comptabilité (pièce = numéro)") do
        entries = Acc.entries(actor, Acc::EntryQuery.new(source: "invoice:#{id}"))
        entry = entries.first? || next "aucune écriture"
        sale = entry
        note "#{entry.ledger_code} #{entry.receipt} : #{entry_lines(entry)}"
        entry.total_debit == d("255") || "total #{entry.total_debit}"
      end
      entry = sale || return
      customer = Cards.card(actor, Inv.document(actor, id).customer_card_id)
      account = (Acc.card_account(actor, customer.id) || raise "client sans compte").account.number
      customer_line = entry.lines.find! { |line| line.account_number == account }.id
      bank_and_match(browser, customer.code, d("255"), "Virement #{Inv.document(actor, id).number}", customer_line)
      check("facture encaissée (payment.matched)") do
        view = Inv.document(actor, id)
        view.effective_status == "paid" || view.effective_status
      end
      check("recette inscrite au livre des recettes (lettrage), sans seconde écriture") do
        receipts = Mic.receipts(actor).select(&.source.starts_with?("matching:"))
        next "aucune recette issue du lettrage" if receipts.empty?
        next "montant #{receipts.sum(BigDecimal.new(0), &.amount)}" unless receipts.sum(BigDecimal.new(0), &.amount) == d("255")
        next "écriture en double" unless receipts.all? { |line| Acc.entries(actor, Acc::EntryQuery.new(source: "micro:receipt:#{line.id}")).empty? }
        note "recette #{receipts.map(&.number).join(", ")} du #{receipts.first.date.to_s("%Y-%m-%d")} : #{receipts.first.amount} € (#{receipts.first.source})"
        expect(browser.get("/micro/receipts?year=#{year}"), 200, receipts.first.number, "255,00")
      end

      section "Recette et achat saisis au livre → écritures de trésorerie"
      check("recette en espèces de 150 € saisie en quelques champs") do
        redirect?(browser.submit("/micro/receipts/new", {"amount" => "150", "date" => today.to_s("%Y-%m-%d"),
                                                         "nature_id" => micro_nature("SALE").id.to_s, "method" => "cash",
                                                         "party_name" => "Client au comptoir", "label" => "Vente comptoir"}), "/micro/receipts")
      end
      check("écriture de trésorerie générée pour la recette") do
        line = Mic.receipts(actor).find { |item| item.party_name == "Client au comptoir" } || next "recette absente"
        entry = Acc.entries(actor, Acc::EntryQuery.new(source: "micro:receipt:#{line.id}")).first? || next "aucune écriture"
        note "recette #{line.number} → #{entry.ledger_code} #{entry.receipt} : #{entry_lines(entry)}"
        entry.total_debit == d("150") || "total #{entry.total_debit}"
      end
      check("achat de 42 € saisi au registre des achats, écriture générée") do
        response = browser.submit("/micro/purchases/new", {"amount" => "42", "date" => today.to_s("%Y-%m-%d"),
                                                           "nature_id" => Mic.natures(system, "purchase").first.id.to_s, "method" => "card",
                                                           "party_name" => "Papeterie Centrale"})
        next redirect?(response, "/micro/purchases") unless response.status_code == 302
        line = Mic.purchases(actor).first? || next "achat absent"
        entry = Acc.entries(actor, Acc::EntryQuery.new(source: "micro:purchase:#{line.id}")).first? || next "aucune écriture"
        note "achat #{line.number} → #{entry.ledger_code} #{entry.receipt} : #{entry_lines(entry)}"
        true
      end

      section "URSSAF"
      Mic.declarations(actor, year).select { |item| item.ends_on < today && item.status.in?("due", "late") }.each do |item|
        check("déclaration passée du #{item.starts_on.to_s("%d/%m")} au #{item.ends_on.to_s("%d/%m")} notée (#{item.turnover} €)") do
          response = browser.post("/micro/urssaf/declare", {"starts_on" => item.starts_on.to_s("%Y-%m-%d"), "reference" => "DEC-#{item.starts_on.to_s("%Y%m")}"})
          next redirect?(response, "/micro/urssaf") unless response.status_code == 302
          Mic.declarations(actor, year).find! { |row| row.starts_on == item.starts_on }.status == "declared" || "non notée"
        end
      end
      check("montants à déclarer du trimestre en cours (chiffre d'affaires, cotisations estimées)") do
        declaration = Mic.declarations(actor, year).find { |item| item.starts_on <= today && today <= item.ends_on } || next "période absente"
        next "chiffre d'affaires #{declaration.turnover}" unless declaration.turnover == d("405")
        note "période du #{declaration.starts_on.to_s("%Y-%m-%d")} au #{declaration.ends_on.to_s("%Y-%m-%d")}, échéance #{declaration.due_on.to_s("%Y-%m-%d")} : " \
             "#{declaration.contributions.map { |item| "#{item.category} CA #{item.turnover} → #{item.total}" }.join(" ; ")}, total #{declaration.total} €"
        next "cotisations nulles" unless declaration.total > 0
        page = browser.get("/micro/urssaf?year=#{year}")
        upcoming = Mic.declarations(actor, year).any?(&.status.==("upcoming"))
        next "période à venir non signalée" if upcoming && !text_of(page).includes?("À venir")
        expect(page, 200, "Prochaine déclaration · #{declaration.starts_on.to_s("%d/%m/%Y")}", "À reporter", "150 €", "255 €")
      end
      check("2042-C-PRO : montants de l'année") { expect(browser.get("/micro/tax-return?year=#{year}"), 200, "405 €") }

      section "Seuils"
      check("sous le seuil de la franchise en base de TVA avant la grosse recette") do
        view = Mic.thresholds(actor, year)
        view.thresholds.none? { |item| item.status.in?("exceeded", "tolerance_exceeded") } || "déjà dépassé"
      end
      check("recette de 40 000 € (prestations de services)") do
        redirect?(browser.submit("/micro/receipts/new", {"amount" => "40000", "date" => today.to_s("%Y-%m-%d"),
                                                         "nature_id" => micro_nature("SERVICE").id.to_s, "method" => "transfer",
                                                         "party_name" => "Grand compte", "label" => "Mission annuelle"}), "/micro/receipts")
      end
      check("alerte de seuil : franchise en base de TVA dépassée (écran des seuils et tableau de bord)") do
        view = Mic.thresholds(actor, year)
        over = view.thresholds.select { |item| item.status.in?("exceeded", "tolerance_exceeded") }
        next "aucun seuil dépassé (#{view.thresholds.map { |item| "#{item.kind}/#{item.scope} #{item.status}" }.join(", ")})" if over.empty?
        next "aucune alerte" if view.alerts.empty?
        note over.map { |item| "#{item.kind} #{item.scope} : #{item.turnover} € pour #{item.limit} € (#{item.status})" }.join(" ; ")
        note "alertes : #{view.alerts.map(&.key).join(", ")}"
        page = browser.get("/micro/thresholds?year=#{year}")
        result = expect(page, 200, "Seuil")
        next result unless result == true
        text_of(page).includes?("dépassé") || "« dépassé » absent de l'écran"
      end
    end

    # --- Régime réel : liasse, CA3, DAS2 -----------------------------------------------

    private def teledec_setup(browser : Verif::Browser, tax_system : String, vat_system : String) : Nil
      section "TELEDEC : paramètres et identifiants"
      check("paramètres : régime #{tax_system}, TVA #{vat_system}") do
        page = browser.get("/ext/TELEDEC/settings")
        next expect(page, 200) unless page.status_code == 200
        values = Verif.form_values(page.body).merge({"tax_system" => tax_system, "vat_system" => vat_system})
        redirect?(browser.post("/ext/TELEDEC/settings", values), "/ext/TELEDEC/")
      end
      check("identifiants de l'API enregistrés (clé jamais réaffichée)") do
        response = browser.post("/ext/TELEDEC/settings/credentials", {"login" => Teledec::SimulatedTeledec::LOGIN,
                                                                      "api_key" => Teledec::SimulatedTeledec::API_KEY, "env" => "sandbox"})
        next redirect?(response) unless response.status_code == 302
        page = browser.get("/ext/TELEDEC/settings")
        next "clé affichée" if page.body.includes?(Teledec::SimulatedTeledec::API_KEY)
        expect(page, 200, "Enregistrée")
      end
    end

    # Prépare par l'écran, contrôle, transmet, relève l'accusé.
    private def file(browser : Verif::Browser, label : String, values : Hash(String, String)) : Nil
      filing_url = nil
      check("#{label} : préparée depuis l'écran des échéances") do
        browser.get("/ext/TELEDEC/?fy=#{fiscal_year_id}")
        response = browser.post("/ext/TELEDEC/prepare", values)
        next redirect?(response, "/ext/TELEDEC/filings/") unless response.status_code == 302
        filing_url = response.headers["Location"]
        filing = TApi.filing(actor, filing_url.to_s.split('/').last.to_i64)
        errors = filing.controls.select(&.error?)
        note "dépôt #{filing.id} #{filing.key} : formulaires #{filing.forms.join(", ")}, #{filing.boxes.size} case(s), " \
             "#{filing.balance.size} ligne(s) de balance, #{filing.das2.size} bénéficiaire(s) DAS2, contrôles #{filing.controls.map(&.key).join(", ")}"
        errors.empty? || "contrôles bloquants : #{errors.map(&.key).join(", ")}"
      end
      url = filing_url || return
      id = url.split('/').last.to_i64
      check("#{label} : contrôlée puis transmise au TELEDEC simulé") do
        browser.post("#{url}/check")
        response = browser.post("#{url}/transmit")
        next redirect?(response) unless response.status_code == 302
        filing = TApi.filing(actor, id)
        next "statut #{filing.status} #{filing.last_error}" unless filing.status == "transmitted"
        note "transmise : identifiant TELEDEC #{filing.remote_id}, empreinte #{filing.fingerprint[0, 16]}…"
        expect(browser.get(url), 200, filing.remote_id)
      end
      check("#{label} : accusé de réception relevé, affiché et téléchargeable") do
        response = browser.post("#{url}/refresh")
        next redirect?(response) unless response.status_code == 302
        filing = TApi.filing(actor, id)
        next "statut #{filing.status}" unless filing.status == "acknowledged"
        page = browser.get(url)
        next "accusé non affiché" unless page.body.includes?("data-teledec-receipt") && page.body.includes?(%(data-teledec-filing="acknowledged"))
        receipt = browser.get("#{url}/receipt")
        next "accusé HTTP #{receipt.status_code}" unless receipt.status_code == 200 && receipt.body.starts_with?("%PDF")
        note "accusé du #{filing.acknowledged_at.try(&.to_s("%Y-%m-%d"))} (#{receipt.body.bytesize} octets)"
        true
      end
    end

    private def reel(browser : Verif::Browser) : Nil
      teledec_setup(browser, "is_rsi", "ca3_monthly")
      section "Écritures de l'exercice (vente, honoraires d'avocat)"
      card(browser, "CUSTOMER", "CLI-MOREL", {"name" => "Atelier Morel SAS", "siren" => "552100554",
                                              "address.line1" => "3 rue du Port", "address.postcode" => "44100",
                                              "address.city" => "Nantes", "address.country_code" => "FR"})
      card(browser, "SUPPLIER", "AV-LILAS", {"name" => "Cabinet Lilas Avocats", "siret" => "40483304800006",
                                             "description" => "Avocat", "address.line1" => "3 rue des Lilas",
                                             "address.postcode" => "69003", "address.city" => "Lyon", "address.country_code" => "FR"})
      rate = Partiduo::Api::Vat.rate_by_code(system, "NOR") || raise "taux NOR absent"
      card(browser, "SALE", "CONSEIL", {"name" => "Conseil (heure)", "unit_code" => "HUR", "sale_price" => "80", "vat_rate_id" => rate.id.to_s})
      invoice_id = nil
      check("facture de 50 h de conseil validée (écriture de vente générée)") do
        response = browser.submit("/invoicing/documents/new?kind=invoice", {"kind" => "invoice", "customer" => "CLI-MOREL",
                                                                            "line-0-item" => "CONSEIL", "line-0-quantity" => "50"}, "/invoicing/documents/new")
        next redirect?(response) unless response.status_code == 302
        id = response.headers["Location"].split('/').last.to_i64
        invoice_id = id
        issued = browser.post("/invoicing/documents/#{id}/issue")
        next redirect?(issued) unless issued.status_code == 302
        entry = Acc.entries(actor, Acc::EntryQuery.new(source: "invoice:#{id}")).first? || next "aucune écriture"
        note "#{Inv.document(actor, id).number} → #{entry.ledger_code} #{entry.receipt} : #{entry_lines(entry)}"
        true
      end
      account_6226
      check("honoraires d'avocat de 2 000 € HT saisis au journal d'achats") do
        ledger = Acc.ledgers(system, Acc::LedgerKind::Purchase).first
        values = {"ledger_id" => ledger.id.to_s, "date" => today.to_s("%d/%m/%Y"), "receipt" => "", "label" => "Honoraires contentieux",
                  "third_party" => "AV-LILAS", "due_date" => "", "line-0-account" => "6226", "line-0-label" => "",
                  "line-0-amount" => "2000", "line-0-vat_rate" => "NOR"}
        response = browser.submit("/accounting/entries/purchase", values)
        redirect?(response, "/accounting/entries")
      end

      section "Déclaration de TVA CA3 (lot 4) close"
      vat_id = nil
      check("CA3 de #{today.to_s("%m/%Y")} enregistrée depuis l'écran de préparation") do
        query = URI::Params.encode({"form" => "fr_ca3", "year" => year.to_s, "periodicity" => "month", "number" => today.month.to_s})
        browser.get("/accounting/vat?#{query}&f=1")
        response = browser.post("/accounting/vat/returns/new?#{query}")
        next redirect?(response, "/accounting/vat/returns/") unless response.status_code == 302
        vat_id = response.headers["Location"].split('/').last.split('?').first.to_i64?
        vat_id ? true : "identifiant illisible : #{response.headers["Location"]}"
      end
      if id = vat_id
        check("CA3 close (figée)") do
          page = browser.get("/accounting/vat/returns/#{id}/close")
          values = Verif.form_values(page.body)
          values.delete("settle")
          response = browser.post("/accounting/vat/returns/#{id}/close", values)
          next redirect?(response) unless response.status_code == 302
          view = Acc.vat_return(actor, id)
          note "CA3 #{id} : #{view.boxes.reject(&.amount.zero?).map { |box| "#{box.code} #{box.amount}" }.join(" ; ")}"
          view.closed? || "non close"
        end
      end

      section "Télédéclarations transmises au TELEDEC simulé"
      file(browser, "liasse (2065, 2033)", {"kind" => "liasse", "fiscal_year_id" => fiscal_year_id.to_s})
      vat_id.try { |vat| file(browser, "TVA CA3", {"kind" => "vat_ca3", "vat_return_id" => vat.to_s}) }
      file(browser, "DAS2 #{year}", {"kind" => "das2", "year" => year.to_s})
      check("DAS2 : l'avocat déclaré (honoraires TTC au-dessus de 1 200 €)") do
        filing = TApi.filings(actor, fiscal_year_id).find { |item| item.kind == "das2" } || next "dépôt absent"
        lines = TApi.filing(actor, filing.id).das2
        note lines.map { |line| "#{line.name} #{line.siret} : #{line.total} (#{line.amounts.map { |k, v| "#{k} #{v}" }.join(", ")})" }.join(" ; ")
        !lines.empty? || "aucun bénéficiaire"
      end
      check("écran des échéances : trois dépôts accusés") do
        page = browser.get("/ext/TELEDEC/?fy=#{fiscal_year_id}")
        count = page.body.scan(%(data-teledec-status="acknowledged")).size
        count >= 3 || "#{count} dépôt(s) accusé(s)"
      end
    end

    private def account_6226 : Nil
      Acc.account(system, "6226")
    rescue Partiduo::Api::NotFound
      Acc.create_account(system, Acc::AccountInput.new(number: "6226", label: "Honoraires", parent: "62")).value!
    end

    # --- Profession libérale : 2035 ------------------------------------------------------

    private def lib_nature(heading : String) : Lib::NatureView
      Lib.natures(system).find { |nature| nature.heading == heading && nature.enabled } || raise "nature #{heading} absente"
    end

    private def liberal(browser : Verif::Browser) : Nil
      section "Paramètres de la profession libérale"
      check("tableau de bord simplifié (profession libérale)") { expect(browser.get("/"), 200, "pd-simple") }
      check("paramètres : profession, début d'activité") do
        redirect?(browser.submit("/liberal/settings", {"profession" => "Masseur-kinésithérapeute", "activity_started_on" => "2020-01-01",
                                                       "default_nature_id" => lib_nature("receipts").id.to_s}), "/")
      end

      section "Recettes et dépenses ventilées par rubrique"
      entries_before = Acc.count_entries(system)
      [
        {"receipts", "receipt", "4800", "Honoraires de septembre", "0"},
        {"receipts", "receipt", "1200", "Honoraires de séances à domicile", "0"},
        {"rent", "expense", "900", "Loyer du cabinet", "0"},
        {"vehicle", "expense", "400", "Carburant et entretien", "100"},
      ].each do |(heading, kind, amount, label, private_part)|
        check("#{kind == "receipt" ? "recette" : "dépense"} de #{amount} € (#{heading}#{private_part == "0" ? "" : ", part privée #{private_part} €"})") do
          path = kind == "receipt" ? "/liberal/receipts/new" : "/liberal/expenses/new"
          values = {"amount" => amount, "date" => today.to_s("%Y-%m-%d"), "nature_id" => lib_nature(heading).id.to_s,
                    "method" => "transfer", "party_name" => "", "label" => label}
          values["nondeductible_amount"] = private_part if kind == "expense"
          redirect?(browser.submit(path, values), kind == "receipt" ? "/liberal/receipts" : "/liberal/expenses")
        end
      end
      check("ventilation de l'année : recettes 6 000, loyer 900, véhicule 400 dont 100 non déductibles") do
        totals = Lib.heading_totals(actor, year)
        by = totals.to_h { |item| {item.heading, item} }
        note totals.map { |item| "#{item.heading} #{item.amount} (#{item.nondeductible_amount} non déd.)" }.join(" ; ")
        next "recettes #{by["receipts"]?.try(&.amount)}" unless by["receipts"]?.try(&.amount) == d("6000")
        next "loyer #{by["rent"]?.try(&.amount)}" unless by["rent"]?.try(&.amount) == d("900")
        next "véhicule" unless by["vehicle"]?.try(&.nondeductible_amount) == d("100")
        expect(browser.get("/liberal/journal?year=#{year}"), 200, "Livre-journal #{year}", "Dont")
      end

      section "Immobilisation amortie"
      asset_id = nil
      check("table de massage de 3 000 € acquise le 1er avril, amortie sur 3 ans") do
        response = browser.submit("/liberal/assets/new", {"amount" => "3000", "label" => "Table de massage électrique",
                                                          "category" => "equipment", "acquired_on" => "#{year}-04-01",
                                                          "duration_years" => "3", "method" => "transfer"})
        next redirect?(response, "/liberal/assets/") unless response.status_code == 302
        asset_id = response.headers["Location"].split('/').last.to_i64
        expect(browser.follow(response), 200, "Plan d'amortissement", "750,00")
      end
      check("dotation de l'année : 750,00 € (prorata sur 360 jours)") do
        row = Lib.depreciation(actor, year).find { |item| item.asset_id == asset_id } || next "absente du tableau"
        note "#{row.number} : base #{row.amount}, taux #{row.rate}, dotation #{row.year_amount}, valeur nette #{row.net_value}"
        row.year_amount == d("750") || "dotation #{row.year_amount}"
      end
      check("écritures de trésorerie générées par la Comptabilité (recettes, dépenses, immobilisation)") do
        created = Acc.count_entries(system) - entries_before
        note "#{created} écriture(s) générée(s)"
        created >= 5 || "#{created} écriture(s)"
      end

      section "Déclaration 2035 préparée"
      check("2035 de l'année : sans contrôle bloquant, cases de la 2035-A") do
        view = Lib.tax_return(actor, year)
        lines = view.lines.reject(&.amount.zero?)
        note lines.map { |line| "#{line.form} l.#{line.line} #{line.box} #{line.amount}" }.join(" ; ")
        note "contrôles : #{view.controls.map { |control| "#{control.key} (#{control.severity})" }.join(", ")}" unless view.controls.empty?
        next "contrôles bloquants" unless view.ready?
        expect(browser.get("/liberal/tax-return?year=#{year}"), 200, "2035")
      end
      check("édition de contrôle PDF de la 2035") do
        pdf = browser.get("/liberal/tax-return?year=#{year}&format=pdf")
        pdf.status_code == 200 && pdf.body.starts_with?("%PDF") || "HTTP #{pdf.status_code}"
      end
      teledec_setup(browser, "bnc", "none")
      section "Transmission de la 2035 au TELEDEC simulé"
      file(browser, "liasse BNC (2035)", {"kind" => "liasse", "fiscal_year_id" => fiscal_year_id.to_s})
      check("dépôt : 2035 du module jointe (empreinte identique)") do
        filing = TApi.filings(actor, fiscal_year_id).find { |item| item.kind == "liasse" } || next "dépôt absent"
        view = TApi.filing(actor, filing.id)
        next "formulaires #{view.forms}" unless view.forms.includes?("2035")
        fingerprint = Lib.tax_return(actor, year).fingerprint
        note "détails : #{view.details.keys.join(", ")}"
        view.details.values.any?(&.==(fingerprint)) || "empreinte de la 2035 absente du dépôt"
      end
    end
  end
end

profile = "micro"
host = ""
email = ""
password = ENV["PARTIDUO_DEMO_PASSWORD"]? || "Verif-lotT-Partiduo-2026"
invitation = nil
port = 8130
keep = false
serve_only = false
OptionParser.parse do |parser|
  parser.banner = "Usage : crystal run scripts/verif_t.cr -- --profile=micro|reel|liberal --host=HÔTE --email=ADRESSE [--invitation=LIEN] [--port=N] [--keep]"
  parser.on("--profile=NAME", "micro, reel ou liberal") { |value| profile = value }
  parser.on("--host=HOST", "hôte de l'instance") { |value| host = value }
  parser.on("--email=EMAIL", "adresse de l'administrateur") { |value| email = value }
  parser.on("--password=PASSWORD", "mot de passe") { |value| password = value }
  parser.on("--invitation=LINK", "lien d'invitation (premier passage)") { |value| invitation = value }
  parser.on("--port=PORT", "port local du serveur") { |value| port = value.to_i }
  parser.on("--keep", "laisse le serveur ouvert après le parcours") { keep = true }
  parser.on("--serve-only", "sert l'instance sans rejouer le parcours (essai dans un navigateur)") { serve_only = true }
end
abort "--email et --host sont obligatoires" if email.empty? || host.empty?

Marten.configure(&.log_level=(::Log::Severity::Warn))
Marten.setup
Verif.serve(port)
if serve_only
  Teledec::Transports.current = VerifT::AutoAckTeledec.new
  puts "== Serveur ouvert : http://#{host}:#{port}/ (TELEDEC simulé ; Ctrl-C pour arrêter)"
  sleep
end
run = VerifT::Run.new(profile, host, port, email, password, invitation)
run.run
puts run.failures.zero? ? "== Tout est vert (#{run.steps} étapes)." : "== #{run.failures} étape(s) en échec sur #{run.steps} : #{run.failed.join(" ; ")}"
if keep
  puts "== Serveur ouvert : http://#{host}:#{port}/ (Ctrl-C pour arrêter)"
  sleep
end
exit(run.failures.zero? ? 0 : 1)
