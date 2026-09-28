# SPDX-License-Identifier: AGPL-3.0-or-later

module Teledec
  # Contrat public de l'extension, sur le modèle de `Partiduo::Api`
  # (DECISIONS C2) : acteur en premier argument, contrôle d'accès en
  # première ligne, objets de vue immuables, jamais un modèle Marten en
  # retour ; `ModuleDisabled` si l'extension est inactive. L'interface
  # (`ui/bulma/`) ne voit que ce module. Documentation :
  # `doc/api/teledec.adoc`.
  module Api
    alias Actor = Partiduo::Api::Actor
    alias Guard = Partiduo::Api::Guard
    alias FieldError = Partiduo::Api::FieldError
    alias Result = Partiduo::Api::Result

    MODULE_CODE = Teledec::CODE
    READ        = "teledec.return.read"
    PREPARE     = "teledec.return.prepare"
    TRANSMIT    = "teledec.return.transmit"
    SETTINGS    = "teledec.settings.manage"

    KINDS        = Config::KINDS
    TAX_SYSTEMS  = Config::TAX_SYSTEMS
    VAT_SYSTEMS  = Config::VAT_SYSTEMS
    STATUSES     = Config::STATUSES
    ENVIRONMENTS = Config::ENVIRONMENTS
    DAS2_NATURES = Config::DAS2_NATURES

    # Issues qu'un utilisateur peut noter pour un dépôt fait hors de
    # Partiduo.
    OUTCOMES = %w[transmitted acknowledged rejected]

    # --- Paramètres ------------------------------------------------------------

    # Paramètres ; la clé de l'API n'est jamais rendue (`key_stored`).
    def self.settings(actor : Actor) : SettingsView
      Guard.authorize!(actor, READ, module_code: MODULE_CODE)
      settings_view(Settings.current!)
    end

    def self.update_settings(actor : Actor, input : SettingsInput) : Result(SettingsView)
      Guard.authorize!(actor, SETTINGS, module_code: MODULE_CODE)
      errors = [] of FieldError
      unless input.tax_system.empty? || TAX_SYSTEMS.includes?(input.tax_system)
        errors << FieldError.new("tax_system", "teledec.errors.settings.tax_system_unknown")
      end
      unless input.vat_system.empty? || VAT_SYSTEMS.includes?(input.vat_system)
        errors << FieldError.new("vat_system", "teledec.errors.settings.vat_system_unknown")
      end
      accounts = input.das2_accounts
      accounts.try &.each do |prefix, nature|
        unless prefix.matches?(/\A[0-9]{2,10}\z/) && DAS2_NATURES.includes?(nature)
          errors << FieldError.new("das2_accounts", "teledec.errors.settings.das2_account", {"account" => prefix})
        end
      end
      if (threshold = input.das2_threshold) && threshold < 0
        errors << FieldError.new("das2_threshold", "teledec.errors.settings.das2_threshold")
      end
      return Result(SettingsView).failure(errors) unless errors.empty?

      Partiduo::Api::Transaction.run do
        settings = Settings.current!
        settings.tax_system = input.tax_system
        settings.vat_system = input.vat_system
        settings.greffe = input.greffe
        settings.das2_accounts = accounts.empty? ? "" : accounts.to_json if accounts
        input.das2_threshold.try { |value| settings.das2_threshold = value }
        settings.updated_by_id = actor.user_id
        settings.save!
        Result(SettingsView).success(settings_view(settings))
      end
    end

    # Enregistre les identifiants de l'API, chiffrés ; vérifiés auprès de
    # TELEDEC si le transport est branché. `api_key` vide garde la clé
    # enregistrée.
    def self.save_credentials(actor : Actor, input : CredentialsInput) : Result(SettingsView)
      Guard.authorize!(actor, SETTINGS, module_code: MODULE_CODE)
      settings = Settings.current!
      errors = [] of FieldError
      login = input.login.strip
      errors << FieldError.new("login", "teledec.errors.credentials.login") if login.empty? || login.size > 255
      errors << FieldError.new("env", "teledec.errors.credentials.env") unless ENVIRONMENTS.includes?(input.env)
      key = input.api_key.strip
      key = Secrets.decrypt(settings.api_key.to_s) if key.empty? && !settings.api_key.to_s.empty?
      errors << FieldError.new("api_key", "teledec.errors.credentials.api_key") if key.empty?
      return Result(SettingsView).failure(errors) unless errors.empty?

      credentials = Credentials.new(login, key, input.env)
      checked = nil
      if transport = Transports.current
        begin
          transport.check(credentials)
          checked = Time.utc
        rescue ex : TransportError
          return Result(SettingsView).failure(FieldError.new("api_key", ex.key, ex.params))
        end
      end
      Partiduo::Api::Transaction.run do
        settings.login = login
        settings.api_key = Secrets.encrypt(key)
        settings.env = input.env
        settings.checked_at = checked
        settings.updated_by_id = actor.user_id
        settings.save!
        Result(SettingsView).success(settings_view(settings))
      end
    end

    def self.clear_credentials(actor : Actor) : SettingsView
      Guard.authorize!(actor, SETTINGS, module_code: MODULE_CODE)
      settings = Settings.current!
      settings.login = ""
      settings.api_key = ""
      settings.checked_at = nil
      settings.updated_by_id = actor.user_id
      settings.save!
      settings_view(settings)
    end

    # --- Échéances et dépôts ---------------------------------------------------

    # Déclarations attendues pour l'exercice, par échéance, avec leur dépôt.
    def self.schedule(actor : Actor, fiscal_year_id : Int64) : Array(DeadlineView)
      Guard.authorize!(actor, READ, module_code: MODULE_CODE)
      fiscal_year = Builder.find_fiscal_year(fiscal_year_id) || raise Partiduo::Api::NotFound.new("fiscal_year", fiscal_year_id)
      Filings.schedule(fiscal_year)
    end

    # Dépôts, du plus récent au plus ancien ; `fiscal_year_id` : ceux de
    # l'exercice seulement.
    def self.filings(actor : Actor, fiscal_year_id : Int64? = nil) : Array(FilingView)
      Guard.authorize!(actor, READ, module_code: MODULE_CODE)
      query = fiscal_year_id ? Filing.filter(fiscal_year_id: fiscal_year_id) : Filing.all
      query.order("-period_to", "-id").to_a.map { |filing| Filings.view(filing) }
    end

    def self.filing(actor : Actor, id : Int64) : FilingView
      Guard.authorize!(actor, READ, module_code: MODULE_CODE)
      Filings.view(find(id))
    end

    # Historique d'un dépôt (préparations, transmission, accusé, rejets,
    # erreurs du transport).
    def self.events(actor : Actor, id : Int64) : Array(EventView)
      Guard.authorize!(actor, READ, module_code: MODULE_CODE)
      Filings.events(find(id).id!.to_i64)
    end

    # Prépare (ou prépare de nouveau) une déclaration : document, contrôles,
    # échéance. Exige aussi le droit de lire les éditions de la Comptabilité
    # (et de déclarer la TVA pour CA3 et CA12).
    def self.prepare(actor : Actor, input : PrepareInput) : Result(FilingView)
      Guard.authorize!(actor, PREPARE, module_code: MODULE_CODE)
      authorize_sources!(actor, input.kind)
      built = Builder.build(input, Settings.current!)
      return Result(FilingView).failure(built.errors) if built.failure?
      saved = Filings.save(built.value!, actor.user_id)
      return Result(FilingView).failure(saved.errors) if saved.failure?
      Result(FilingView).success(Filings.view(saved.value!))
    end

    # Contrôle de nouveau un dépôt préparé : relit les écritures ; une
    # modification depuis la préparation est une erreur (`changed`) :
    # préparer de nouveau.
    def self.check(actor : Actor, id : Int64) : Result(FilingView)
      Guard.authorize!(actor, PREPARE, module_code: MODULE_CODE)
      filing = find(id)
      authorize_sources!(actor, filing.kind.to_s)
      unless filing.status == "prepared"
        return Result(FilingView).failure(FieldError.base("teledec.errors.filing.status",
          {"status" => I18n.t("teledec.statuses.#{filing.status}")}))
      end
      built = Builder.build(input_of(filing), Settings.current!)
      return Result(FilingView).failure(built.errors) if built.failure?
      controls = built.value!.controls
      if built.value!.payload.fingerprint != filing.fingerprint
        controls = controls + [Builder.error("teledec.controls.changed")]
      end
      filing.controls = controls.to_json
      filing.save!
      Result(FilingView).success(Filings.view(filing))
    end

    # Transmet un dépôt préparé à TELEDEC. Refus : dépôt non préparé,
    # document modifié depuis la préparation, contrôle bloquant, transport
    # absent (adaptateur réel en attente, BLOCAGES B-TDC-001), identifiants
    # absents, erreur de TELEDEC (notée dans l'historique).
    def self.transmit(actor : Actor, id : Int64) : Result(FilingView)
      Guard.authorize!(actor, TRANSMIT, module_code: MODULE_CODE)
      filing = find(id)
      authorize_sources!(actor, filing.kind.to_s)
      unless filing.status == "prepared"
        return Result(FilingView).failure(FieldError.base("teledec.errors.filing.status",
          {"status" => I18n.t("teledec.statuses.#{filing.status}")}))
      end
      built = Builder.build(input_of(filing), Settings.current!)
      return Result(FilingView).failure(built.errors) if built.failure?
      if built.value!.payload.fingerprint != filing.fingerprint
        return Result(FilingView).failure(FieldError.base("teledec.errors.filing.changed"))
      end
      blocking = built.value!.controls.count(&.error?)
      if blocking > 0
        return Result(FilingView).failure(FieldError.base("teledec.errors.filing.not_ready", {"count" => blocking.to_s}))
      end
      transport = Transports.current || return Result(FilingView).failure(FieldError.base("teledec.errors.transport.unavailable"))
      settings = Settings.current!
      credentials = Filings.credentials(settings) || return Result(FilingView).failure(FieldError.base("teledec.errors.credentials.missing"))

      # Clé d'idempotence : dépôt, rang de la transmission (un dépôt rejeté
      # puis préparé de nouveau est un nouvel envoi), empreinte.
      attempt = FilingEvent.filter(filing_id: filing.id, status: "transmitted").count + 1
      submission = Submission.new("partiduo-#{filing.id}-#{attempt}-#{filing.fingerprint.to_s[0, 16]}", filing.kind.to_s,
        filing.forms.to_s.split(','), filing.payload.to_s, filing.fingerprint.to_s)
      remote_id = begin
        transport.submit(credentials, submission)
      rescue ex : TransportError
        filing.last_error = ex.key
        filing.save!
        Filings.event(filing, "error", ex.key, actor.user_id)
        return Result(FilingView).failure(FieldError.base(ex.key, ex.params))
      end
      Partiduo::Api::Transaction.run do
        filing.status = "transmitted"
        filing.remote_id = remote_id
        filing.last_error = ""
        filing.transmitted_at = Time.utc
        filing.transmitted_by_id = actor.user_id
        filing.save!
        Filings.event(filing, "transmitted", remote_id, actor.user_id)
        Result(FilingView).success(Filings.view(filing))
      end
    end

    # Interroge TELEDEC sur un dépôt transmis : accusé de réception
    # (conservé en pièce jointe du socle) ou rejet (motif).
    def self.refresh(actor : Actor, id : Int64) : Result(FilingView)
      Guard.authorize!(actor, TRANSMIT, module_code: MODULE_CODE)
      filing = find(id)
      if filing.status != "transmitted" || filing.manual
        return Result(FilingView).failure(FieldError.base("teledec.errors.filing.status",
          {"status" => I18n.t("teledec.statuses.#{filing.status}")}))
      end
      transport = Transports.current || return Result(FilingView).failure(FieldError.base("teledec.errors.transport.unavailable"))
      credentials = Filings.credentials(Settings.current!) || return Result(FilingView).failure(FieldError.base("teledec.errors.credentials.missing"))
      remote = begin
        transport.status(credentials, filing.remote_id.to_s)
      rescue ex : TransportError
        filing.last_error = ex.key
        filing.save!
        return Result(FilingView).failure(FieldError.base(ex.key, ex.params))
      end
      apply_outcome(filing, remote.state, remote.reason, remote.receipt, remote.at, actor)
    end

    # Interroge TELEDEC sur tous les dépôts transmis ; rend le nombre de
    # dépôts dont le statut a changé.
    def self.refresh_all(actor : Actor) : Int32
      Guard.authorize!(actor, TRANSMIT, module_code: MODULE_CODE)
      return 0 unless Transports.available?
      Filing.filter(status: "transmitted", manual: false).to_a.count do |filing|
        result = refresh(actor, filing.id!.to_i64)
        result.success? && result.value!.status != "transmitted"
      end
    end

    # Note l'issue d'un dépôt fait hors de Partiduo (repli : balance
    # importée sur le site de TELEDEC) : transmis, accusé (pièce jointe
    # facultative) ou rejeté (motif obligatoire).
    def self.record_outcome(actor : Actor, id : Int64, input : OutcomeInput) : Result(FilingView)
      Guard.authorize!(actor, TRANSMIT, module_code: MODULE_CODE)
      filing = find(id)
      errors = [] of FieldError
      errors << FieldError.new("status", "teledec.errors.outcome.status") unless OUTCOMES.includes?(input.status)
      allowed = case filing.status
                when "prepared"    then OUTCOMES
                when "transmitted" then %w[acknowledged rejected]
                else                    [] of String
                end
      if errors.empty? && !allowed.includes?(input.status)
        errors << FieldError.base("teledec.errors.filing.status", {"status" => I18n.t("teledec.statuses.#{filing.status}")})
      end
      if input.status == "rejected" && input.reason.strip.empty?
        errors << FieldError.new("reason", "teledec.errors.outcome.reason")
      end
      return Result(FilingView).failure(errors) unless errors.empty?

      receipt = nil
      if (io = input.receipt) && (name = input.receipt_filename.presence)
        receipt = Receipt.new(name, input.receipt_content_type || "application/pdf", io.getb_to_end)
      end
      if filing.status == "prepared"
        filing.manual = true
        filing.remote_id = input.reference.strip[0, 128]
        filing.transmitted_at = Time.utc
        filing.transmitted_by_id = actor.user_id
        filing.status = "transmitted"
        filing.save!
        Filings.event(filing, "transmitted", I18n.t("teledec.events.manual"), actor.user_id)
        return Result(FilingView).success(Filings.view(filing)) if input.status == "transmitted"
      end
      apply_outcome(filing, input.status == "acknowledged" ? "acknowledged" : "rejected", input.reason.strip, receipt, nil, actor)
    end

    # --- Fichiers ----------------------------------------------------------------

    # Balance de l'exercice au format d'import courant (repli, ADR-007 D5).
    def self.balance_file(actor : Actor, fiscal_year_id : Int64) : FileView
      Guard.authorize!(actor, PREPARE, module_code: MODULE_CODE)
      authorize_sources!(actor, "liasse")
      fiscal_year = Builder.find_fiscal_year(fiscal_year_id) || raise Partiduo::Api::NotFound.new("fiscal_year", fiscal_year_id)
      raise Partiduo::Api::NotFound.new("fiscal_year", fiscal_year_id) if fiscal_year.starts_on.nil?
      siren = Partiduo::Api::Core.settings(Actor.system).siren.delete(' ').presence || "000000000"
      content = Balance.csv(Balance.compute(fiscal_year))
      FileView.new("#{siren}-balance-#{fiscal_year.ends_on.as(Time).to_s("%Y%m%d")}.csv", "text/csv; charset=utf-8",
        content.to_slice)
    end

    # Document préparé (JSON), tel qu'il est remis au transport.
    def self.export_file(actor : Actor, id : Int64) : FileView
      Guard.authorize!(actor, READ, module_code: MODULE_CODE)
      filing = find(id)
      FileView.new("teledec-#{filing.key.to_s.tr(":", "-")}.json", "application/json", filing.payload.to_s.to_slice)
    end

    # Accusé de réception conservé ; `nil` s'il n'y en a pas.
    def self.receipt_file(actor : Actor, id : Int64) : FileView?
      Guard.authorize!(actor, READ, module_code: MODULE_CODE)
      attachment_id = find(id).receipt_attachment_id || return
      system = Actor.system
      attachment = Partiduo::Api::Core.attachment(system, attachment_id.to_i64)
      FileView.new(attachment.filename, attachment.content_type,
        Partiduo::Api::Core.attachment_content(system, attachment_id.to_i64))
    end

    # Nom du transport branché, `nil` s'il n'y en a pas.
    def self.transport_name(actor : Actor) : String?
      Guard.authorize!(actor, READ, module_code: MODULE_CODE)
      Transports.current.try(&.name)
    end

    # --- Interne -----------------------------------------------------------------

    private def self.find(id : Int64) : Filing
      Filing.filter(id: id).first || raise Partiduo::Api::NotFound.new("teledec_filing", id)
    end

    private def self.authorize_sources!(actor : Actor, kind : String) : Nil
      if kind.starts_with?("vat_")
        Guard.authorize!(actor, "accounting.vat.declare", module_code: "ACCOUNTING")
      else
        Guard.authorize!(actor, "accounting.report.read", module_code: "ACCOUNTING")
      end
    end

    private def self.input_of(filing : Filing) : PrepareInput
      details = Payload.from_json(filing.payload.to_s).details
      amount = case filing.kind
               when "is_2571" then details["amount"]?.try { |text| Money.parse(text) }
               when "is_2572" then details["tax"]?.try { |text| Money.parse(text) }
               end
      PrepareInput.new(kind: filing.kind.to_s, fiscal_year_id: filing.fiscal_year_id.try(&.to_i64),
        year: filing.year.try(&.to_i32), number: filing.number.try(&.to_i32) || 0,
        vat_return_id: filing.vat_return_id.try(&.to_i64), amount: amount, confidential: details["confidential"]? == "1")
    end

    private def self.apply_outcome(filing : Filing, state : String, reason : String, receipt : Receipt?, at : Time?,
                                   actor : Actor) : Result(FilingView)
      return Result(FilingView).success(Filings.view(filing)) unless state == "acknowledged" || state == "rejected"
      Partiduo::Api::Transaction.run do
        if receipt
          stored = Partiduo::Api::Core.store_attachment(Actor.system,
            Partiduo::Api::Core::AttachmentInput.new(receipt.filename, receipt.content_type, IO::Memory.new(receipt.content)))
          next Result(FilingView).failure(stored.errors) if stored.failure?
          filing.receipt_attachment_id = stored.value!.id
        end
        if state == "acknowledged"
          filing.status = "acknowledged"
          filing.acknowledged_at = at || Time.utc
          Filings.event(filing, "acknowledged", receipt.try(&.filename) || "", actor.user_id)
        else
          filing.status = "rejected"
          filing.rejection_reason = reason.presence || I18n.t("teledec.events.no_reason")
          filing.rejected_at = at || Time.utc
          Filings.event(filing, "rejected", filing.rejection_reason.to_s, actor.user_id)
        end
        filing.last_error = ""
        filing.save!
        Result(FilingView).success(Filings.view(filing))
      end
    end

    private def self.settings_view(settings : Settings) : SettingsView
      SettingsView.new(
        tax_system: settings.tax_system.to_s,
        vat_system: settings.vat_system.to_s,
        greffe: settings.greffe || false,
        das2_accounts: Filings.das2_accounts(settings),
        das2_threshold: settings.das2_threshold || Config::DAS2_THRESHOLD,
        env: settings.env.to_s,
        login: settings.login.to_s,
        key_stored: !settings.api_key.to_s.empty?,
        checked_at: settings.checked_at,
        transport: Transports.current.try(&.name),
        forms: Config::FORMS[settings.tax_system.to_s]? || [] of String,
      )
    end
  end
end
