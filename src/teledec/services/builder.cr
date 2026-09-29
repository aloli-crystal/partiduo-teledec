# SPDX-License-Identifier: AGPL-3.0-or-later

module Teledec
  # Préparation d'une déclaration : document (`Payload`), contrôles et
  # repères du dépôt (clé, période, échéance). Ne calcule jamais les cases
  # de la liasse (formule API Balance, ADR-007 D4) ; reprend les cases des
  # déclarations préparées ailleurs (TVA du lot 4, 2035 du module
  # `liberal`). Toutes les lectures passent par `Partiduo::Api` avec
  # l'acteur système, après le contrôle des droits par `Teledec::Api`.
  # Sans la Comptabilité, seule la liasse 2035 est construite, à partir de
  # la 2035 de `liberal` ; toute autre sorte est refusée avant la moindre
  # lecture de la Comptabilité (`Sources`, DECISIONS D-TDC2-002).
  module Builder
    alias FieldError = Partiduo::Api::FieldError
    alias ControlView = Api::ControlView
    alias Core = Partiduo::Api::Core
    alias Acc = Partiduo::Api::Accounting

    record Built,
      key : String,
      kind : String,
      forms : Array(String),
      fiscal_year_id : Int64?,
      year : Int32,
      number : Int32,
      period_from : Time,
      period_to : Time,
      due_on : Time?,
      vat_return_id : Int64?,
      payload : Payload,
      controls : Array(ControlView)

    # Années civiles admises pour la DAS2 (saisie bornée : `Time.utc`
    # refuse les années hors de 1..9999).
    YEARS = 2000..2100

    def self.system : Partiduo::Api::Actor
      Partiduo::Api::Actor.system
    end

    def self.error(key : String, params = {} of String => String) : ControlView
      ControlView.new(key, params, "error")
    end

    def self.warning(key : String, params = {} of String => String) : ControlView
      ControlView.new(key, params, "warning")
    end

    def self.build(input : Api::PrepareInput, settings : Settings) : Partiduo::Api::Result(Built)
      failure = ->(field : String, key : String) { Partiduo::Api::Result(Built).failure(FieldError.new(field, key)) }
      return failure.call("kind", "teledec.errors.kind.unknown") unless Config::KINDS.includes?(input.kind)
      accounting = Sources.accounting?
      tax_system = Sources.tax_system(settings, accounting)
      if !accounting && Sources.needs_accounting?(input.kind, tax_system)
        return failure.call(FieldError::BASE, Sources::ACCOUNTING_REQUIRED)
      end
      company = Core.settings(system)
      return failure.call(FieldError::BASE, "teledec.errors.regime") unless company.tax_regime == "fr"

      case input.kind
      when "vat_ca3", "vat_ca12"
        vat(input, company, settings)
      when "das2"
        das2(input, company, settings)
      else
        fiscal_year = input.fiscal_year_id.try { |id| find_fiscal_year(id) }
        return failure.call("fiscal_year_id", "teledec.errors.fiscal_year.unknown") if fiscal_year.nil? || fiscal_year.starts_on.nil? || fiscal_year.ends_on.nil?
        yearly(input, company, settings, fiscal_year, tax_system, accounting)
      end
    end

    # --- Liasse, greffe, IS --------------------------------------------------

    private def self.yearly(input, company, settings, fiscal_year, tax_system, accounting) : Partiduo::Api::Result(Built)
      if invalid = yearly_error(input, settings, tax_system)
        return Partiduo::Api::Result(Built).failure(invalid)
      end
      starts_on = fiscal_year.starts_on.as(Time)
      ends_on = fiscal_year.ends_on.as(Time)
      controls = identity_controls(company)
      number = input.kind == "is_2571" ? input.number : 0
      content = case input.kind
                when "liasse", "greffe"
                  accounting ? balance_content(input, tax_system, fiscal_year, controls) : liberal_content(fiscal_year, controls)
                when "is_2572" then corporate_tax_balance_content(input, fiscal_year, controls)
                else                corporate_tax_advance_content(input, controls)
                end
      balance, previous, boxes, details = content
      key = input.kind == "is_2571" ? "is_2571:#{fiscal_year.id}:#{number}" : "#{input.kind}:#{fiscal_year.id}"
      forms = Config.forms(input.kind, tax_system)
      payload = Payload.new(input.kind, forms, identity(company), day(starts_on), day(ends_on), number, balance,
        previous, boxes, nil, details)
      Partiduo::Api::Result(Built).success(Built.new(key, input.kind, forms, fiscal_year.id, ends_on.year, number,
        starts_on, ends_on, yearly_due(input.kind, starts_on, ends_on, number), nil, payload, controls))
    end

    alias Content = {Array(Payload::BalanceRow)?, Array(Payload::BalanceRow)?, Hash(String, Hash(String, String))?, Hash(String, String)}

    # Règles de saisie de la liasse, du greffe et des relevés d'IS.
    private def self.yearly_error(input : Api::PrepareInput, settings : Settings, tax_system : String) : FieldError?
      return FieldError.base("teledec.errors.settings.tax_system") if input.kind != "greffe" && tax_system.empty?
      if input.kind.starts_with?("is_") && !Config::CORPORATE_TAX_SYSTEMS.includes?(tax_system)
        return FieldError.base("teledec.errors.corporate_tax.not_applicable")
      end
      return FieldError.base("teledec.errors.greffe.disabled") if input.kind == "greffe" && !settings.greffe
      return FieldError.new("number", "teledec.errors.number.invalid") if input.kind == "is_2571" && !(1 <= input.number <= 4)
      amount = input.amount
      return FieldError.new("amount", "teledec.errors.amount.invalid") if input.kind == "is_2571" && amount.nil?
      return FieldError.new("amount", "teledec.errors.amount.invalid") if amount && amount < 0
      nil
    end

    private def self.yearly_due(kind : String, starts_on : Time, ends_on : Time, number : Int32) : Time?
      case kind
      when "liasse"  then Calendar.liasse(ends_on)
      when "greffe"  then Calendar.greffe(ends_on)
      when "is_2572" then Calendar.corporate_tax_balance(ends_on)
      else                Calendar.corporate_tax_advances(starts_on, ends_on)[number - 1]?
      end
    end

    # Liasse et greffe : balance de l'exercice avant clôture, balance de
    # l'exercice précédent, 2035 préparée pour un BNC tenant le module
    # `liberal`.
    private def self.balance_content(input, tax_system, fiscal_year, controls) : Content
      computed = Balance.compute(fiscal_year)
      balance = computed.rows.map(&.to_payload)
      previous = Balance.previous(fiscal_year).try { |year| Balance.compute(year).rows.map(&.to_payload) }
      controls.concat(balance_controls(computed))
      controls << warning("teledec.controls.fiscal_year_open") unless fiscal_year.closed?
      details = {} of String => String
      details["closing_neutralised"] = "1" if computed.closing_neutralised
      details["confidential"] = input.confidential ? "1" : "0" if input.kind == "greffe"
      boxes = nil
      if input.kind == "liasse" && tax_system == "bnc" && Sources.liberal?
        boxes = liberal_boxes(fiscal_year.ends_on.as(Time).year, controls, details)
      end
      {balance, previous, boxes, details}
    end

    # Liasse 2035 sans la Comptabilité (DECISIONS D-TDC2-002) : aucune
    # balance, les cases de la 2035 préparée par `liberal` seules.
    private def self.liberal_content(fiscal_year, controls) : Content
      controls << warning("teledec.controls.fiscal_year_open") unless fiscal_year.closed?
      details = {"source" => "liberal"}
      boxes = liberal_boxes(fiscal_year.ends_on.as(Time).year, controls, details)
      {nil, nil, boxes, details}
    end

    # Relevé de solde d'IS : impôt de l'exercice (saisi, sinon solde du
    # compte 695), acomptes transmis, solde.
    private def self.corporate_tax_balance_content(input, fiscal_year, controls) : Content
      tax = input.amount || Money.euros(Balance.compute(fiscal_year).signed("695"))
      advances = Filings.corporate_tax_advances(fiscal_year.id)
      controls << warning("teledec.controls.corporate_tax_zero") if tax.zero?
      {nil, nil, nil, {"tax" => Money.euros_text(tax), "advances" => Money.euros_text(advances),
                       "balance" => Money.euros_text(tax - advances)}}
    end

    private def self.corporate_tax_advance_content(input, controls) : Content
      amount = input.amount || Money::ZERO
      controls << warning("teledec.controls.corporate_tax_zero") if amount.zero?
      {nil, nil, nil, {"amount" => Money.euros_text(amount)}}
    end

    # 2035 préparée par le module `liberal` (DECISIONS D-LIB-007) : cases de
    # la déclaration, empreinte de la version préparée.
    private def self.liberal_boxes(year : Int32, controls : Array(ControlView), details : Hash(String, String)) : Hash(String, Hash(String, String))
      prepared = Partiduo::Api::Liberal.tax_return(system, year)
      controls << error("teledec.controls.liberal_not_ready", {"count" => prepared.controls.count(&.error?).to_s}) unless prepared.ready?
      details["tax_return_fingerprint"] = prepared.fingerprint
      prepared.boxes.transform_values { |boxes| boxes.transform_values { |amount| Money.euros_text(amount) } }
    end

    # --- TVA -----------------------------------------------------------------

    private def self.vat(input, company, settings) : Partiduo::Api::Result(Built)
      failure = ->(key : String) { Partiduo::Api::Result(Built).failure(FieldError.new("vat_return_id", key)) }
      id = input.vat_return_id || return failure.call("teledec.errors.vat_return.unknown")
      view = begin
        Acc.vat_return(system, id)
      rescue Partiduo::Api::NotFound
        return failure.call("teledec.errors.vat_return.unknown")
      end
      expected = input.kind == "vat_ca3" ? "fr_ca3" : "fr_ca12"
      return failure.call("teledec.errors.vat_return.form") unless view.form == expected
      return failure.call("teledec.errors.vat_return.open") unless view.closed?

      controls = identity_controls(company)
      wanted = input.kind == "vat_ca3" ? %w[ca3_monthly ca3_quarterly] : %w[ca12]
      unless wanted.includes?(settings.vat_system.to_s)
        controls << warning("teledec.controls.vat_system", {"system" => settings.vat_system.to_s})
      end
      forms = Config.forms(input.kind, "")
      # Cases arrondies à l'euro, totaux recalculés sur les cases arrondies
      # (`VatTotals`, D-TDC-026).
      boxes = VatTotals.coherent(input.kind, view.boxes.to_h { |box| {box.code, box.amount.to_s} })
      # Cases qu'aucun code du formulaire de TELEDEC ne reçoit : la
      # déclaration serait incomplète.
      Remote::Formats.unmapped(input.kind, boxes, view.date_to.year).each do |box|
        controls << error("teledec.controls.box_unmapped", {"box" => box, "form" => forms.first})
      end
      fiscal_year = fiscal_year_for(view.date_to)
      due_on = input.kind == "vat_ca3" ? Calendar.vat_monthly(view.date_to) : Calendar.vat_annual(view.date_to)
      details = {"periodicity" => view.periodicity, "vat_return_id" => id.to_s}
      payload = Payload.new(input.kind, forms, identity(company), day(view.date_from), day(view.date_to), view.number,
        nil, nil, {forms.first => boxes}, nil, details)
      Partiduo::Api::Result(Built).success(Built.new("#{input.kind}:#{day(view.date_from)}", input.kind, forms,
        fiscal_year.try(&.id), view.year, view.number, view.date_from, view.date_to, due_on, id, payload, controls))
    end

    # --- DAS2 ----------------------------------------------------------------

    private def self.das2(input, company, settings) : Partiduo::Api::Result(Built)
      year = input.year || return Partiduo::Api::Result(Built).failure(FieldError.new("year", "teledec.errors.year.blank"))
      unless YEARS.includes?(year)
        return Partiduo::Api::Result(Built).failure(FieldError.new("year", "teledec.errors.year.invalid"))
      end
      controls = identity_controls(company)
      result = Das2.compute(year, Filings.das2_accounts(settings), settings.das2_threshold || Config::DAS2_THRESHOLD)
      lines = result.beneficiaries.map do |item|
        card = Partiduo::Api::Cards.card_by_code(system, item.card_code)
        name = card.try(&.name) || item.card_code
        address = card.try(&.address)
        siret = card.try(&.siret).to_s
        country = address.try(&.country_code).presence || "FR"
        if address.nil? || address.line1.blank? || address.city.blank?
          controls << error("teledec.controls.das2_address", {"name" => name})
        end
        controls << warning("teledec.controls.das2_siret", {"name" => name}) if siret.empty? && country == "FR"
        # Personne physique (fiche fournisseur `individual`) : nom, prénoms
        # et date de naissance à la place de la raison sociale ; nature non
        # précisée : avertissement, déclaré en raison sociale.
        person = card.try(&.individual_supplier?) || false
        card.try { |view| controls.concat(person_controls(view)) }
        Payload::Das2Line.new(item.card_code, name, siret, card.try(&.description).to_s, address.try(&.line1).to_s,
          address.try(&.postcode).to_s, address.try(&.city).to_s, country,
          item.amounts.transform_values { |value| Money.euros_text(value) }, Money.euros_text(item.total),
          person, person ? card.try(&.last_name).to_s : "", person ? card.try(&.first_names).to_s : "",
          person ? card.try(&.birth_date).try(&.to_s("%F")).to_s : "")
      end
      controls << error("teledec.controls.das2_empty", {"year" => year.to_s}) if lines.empty?
      # Nature sans lettre de la DGFiP : la rémunération irait dans une
      # mauvaise case.
      lines.flat_map(&.amounts.keys).uniq!.reject { |nature| Remote::Formats::DAS2_LETTERS.has_key?(nature) }.each do |nature|
        controls << error("teledec.controls.das2_nature", {"nature" => nature})
      end
      result.orphans.each do |orphan|
        controls << warning("teledec.controls.das2_orphan", {"receipt" => orphan.receipt, "amount" => Money.cents(orphan.amount)})
      end
      starts_on, ends_on = Time.utc(year, 1, 1), Time.utc(year, 12, 31)
      forms = Config.forms("das2", "")
      payload = Payload.new("das2", forms, identity(company), day(starts_on), day(ends_on), 0, nil, nil, nil, lines,
        {"threshold" => Money.euros_text(settings.das2_threshold || Config::DAS2_THRESHOLD)})
      Partiduo::Api::Result(Built).success(Built.new("das2:#{year}", "das2", forms, fiscal_year_for(ends_on).try(&.id),
        year, 0, starts_on, ends_on, Calendar.das2(year), nil, payload, controls))
    end

    # Avertissements sur l'identité d'un bénéficiaire : nature du
    # fournisseur non précisée, date de naissance d'une personne physique
    # manquante.
    private def self.person_controls(card : Partiduo::Api::Cards::CardView) : Array(ControlView)
      controls = [] of ControlView
      if card.kind == "supplier" && card.supplier_nature.empty?
        controls << warning("teledec.controls.das2_nature_unset", {"name" => card.name})
      end
      if card.individual_supplier? && card.birth_date.nil?
        controls << warning("teledec.controls.das2_birth_date", {"name" => card.name})
      end
      controls
    end

    # --- Communs -------------------------------------------------------------

    def self.identity(company : Core::SettingsView) : Payload::Identity
      street = [company.street_number, company.street].reject(&.blank?).join(" ")
      Payload::Identity.new(company.company_name, company.legal_form, company.siren.delete(' '), company.vat_number,
        company.rcs, company.share_capital.try { |value| Money.cents(value) }, street, company.postcode, company.city,
        company.country_code, company.email)
    end

    private def self.identity_controls(company : Core::SettingsView) : Array(ControlView)
      controls = [] of ControlView
      controls << error("teledec.controls.siren") if company.siren.blank?
      controls << warning("teledec.controls.address") if company.street.blank? || company.postcode.blank? || company.city.blank?
      controls
    end

    private def self.balance_controls(computed : Balance::Result) : Array(ControlView)
      controls = [] of ControlView
      controls << error("teledec.controls.balance_empty") if computed.rows.empty?
      unless computed.balanced?
        controls << error("teledec.controls.balance_unbalanced",
          {"difference" => Money.cents(computed.total_debit - computed.total_credit)})
      end
      controls
    end

    def self.find_fiscal_year(id : Int64) : Core::FiscalYearView?
      Core.fiscal_year(system, id)
    rescue Partiduo::Api::NotFound
      nil
    end

    def self.fiscal_year_for(day : Time) : Core::FiscalYearView?
      Core.fiscal_years(system).find do |year|
        (starts_on = year.starts_on) && (ends_on = year.ends_on) && starts_on <= day <= ends_on
      end
    end

    def self.day(time : Time) : String
      time.to_s("%Y-%m-%d")
    end
  end
end
