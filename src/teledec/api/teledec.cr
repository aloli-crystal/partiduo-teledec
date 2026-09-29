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

    # États bruts d'un dépôt chez TELEDEC (normalisés en minuscules,
    # `teledec.remote_statuses.*`) ; `notfound` : pas encore de déclaration
    # chez TELEDEC.
    REMOTE_STATUSES = %w[notfound notcompleted readytobesent sent completewitherrors completewithwarnings ok accepted
      erreur rejected]

    # Chemin des rappels de TELEDEC, exposé par l'interface.
    CALLBACK_PATH = Callbacks::PATH

    # Issues qu'un utilisateur peut noter pour un dépôt fait hors de
    # Partiduo.
    OUTCOMES = %w[transmitted acknowledged rejected]

    # --- Paramètres ------------------------------------------------------------

    # Paramètres ; la clé de l'API n'est jamais rendue (`key_stored`),
    # l'identifiant de l'API (`login`) ne l'est qu'aux titulaires de
    # `teledec.settings.manage` (vide pour un simple lecteur).
    def self.settings(actor : Actor) : SettingsView
      Guard.authorize!(actor, READ, module_code: MODULE_CODE)
      settings_view(Settings.current!, actor.can?(SETTINGS))
    end

    def self.update_settings(actor : Actor, input : SettingsInput) : Result(SettingsView)
      Guard.authorize!(actor, SETTINGS, module_code: MODULE_CODE)
      errors = [] of FieldError
      unless input.tax_system.empty? || TAX_SYSTEMS.includes?(input.tax_system)
        errors << FieldError.new("tax_system", "teledec.errors.settings.tax_system_unknown")
      end
      # Sans la Comptabilité, seul le régime BNC (2035 de `liberal`) se
      # télédéclare (DECISIONS D-TDC2-001).
      if errors.empty? && !input.tax_system.empty? && !Sources.tax_systems.includes?(input.tax_system)
        errors << FieldError.new("tax_system", Sources::ACCOUNTING_REQUIRED)
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
        Result(SettingsView).success(settings_view(settings, true))
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
      if key.empty? && !settings.api_key.to_s.empty?
        begin
          key = Secrets.decrypt(settings.api_key.to_s)
        rescue Secrets::Error
          errors << FieldError.new("api_key", "teledec.errors.credentials.unreadable")
        end
      end
      errors << FieldError.new("api_key", "teledec.errors.credentials.api_key") if key.empty? && errors.none?(&.field.==("api_key"))
      email = input.email.strip
      unless email.empty? || (email.size <= 255 && email.matches?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/))
        errors << FieldError.new("email", "teledec.errors.credentials.email")
      end
      siret = input.siret.delete(' ')
      siret_error(siret).try { |error| errors << error }
      return Result(SettingsView).failure(errors) unless errors.empty?

      credentials = Credentials.new(login, key, input.env, Filings.account_email(email), siret)
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
        settings.email = email
        settings.siret = siret
        settings.checked_at = checked
        settings.updated_by_id = actor.user_id
        settings.save!
        Result(SettingsView).success(settings_view(settings, true))
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
      settings_view(settings, true)
    end

    # --- Échéances et dépôts ---------------------------------------------------

    # Déclarations attendues pour l'exercice, par échéance, avec leur dépôt.
    def self.schedule(actor : Actor, fiscal_year_id : Int64) : Array(DeadlineView)
      Guard.authorize!(actor, READ, module_code: MODULE_CODE)
      fiscal_year = Builder.find_fiscal_year(fiscal_year_id) || raise Partiduo::Api::NotFound.new("fiscal_year", fiscal_year_id)
      Filings.schedule(fiscal_year)
    end

    # Dépôts, du plus récent au plus ancien ; `fiscal_year_id` : ceux de
    # l'exercice seulement. Vue résumée (en-tête et contrôles) : le document
    # n'est pas relu ; le détail est rendu par `filing`.
    def self.filings(actor : Actor, fiscal_year_id : Int64? = nil) : Array(FilingSummaryView)
      Guard.authorize!(actor, READ, module_code: MODULE_CODE)
      query = fiscal_year_id ? Filing.filter(fiscal_year_id: fiscal_year_id) : Filing.all
      query.order("-period_to", "-id").to_a.map { |filing| Filings.summary(filing) }
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
    # (et de déclarer la TVA pour CA3 et CA12) ; sans la Comptabilité, le
    # droit de lire le livre-journal de `liberal` pour la 2035, et toute
    # autre sorte est refusée (`teledec.errors.accounting_required`).
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
    # préparer de nouveau. Sous le verrou des dépôts, sur le dépôt relu.
    def self.check(actor : Actor, id : Int64) : Result(FilingView)
      Guard.authorize!(actor, PREPARE, module_code: MODULE_CODE)
      authorize_sources!(actor, find(id).kind.to_s)
      Partiduo::Api::Transaction.run do
        Filings.lock!
        filing = find(id)
        next status_failure(filing) unless filing.status == "prepared"
        built = Builder.build(input_of(filing), Settings.current!)
        next Result(FilingView).failure(built.errors) if built.failure?
        controls = built.value!.controls
        if built.value!.payload.fingerprint != filing.fingerprint
          controls = controls + [Builder.error("teledec.controls.changed")]
        end
        filing.controls = controls.to_json
        filing.save!
        Result(FilingView).success(Filings.view(filing))
      end
    end

    # Transmet un dépôt préparé à TELEDEC. Refus : dépôt non préparé,
    # document modifié depuis la préparation, contrôle bloquant, transport
    # désactivé (`Transports.current = nil`), identifiants
    # absents ou illisibles, erreur de TELEDEC (notée dans l'historique).
    # L'appel à TELEDEC a lieu hors transaction ; l'enregistrement qui suit
    # prend le verrou des dépôts, relit le dépôt et revérifie son statut et
    # son empreinte (une préparation concurrente l'emporte : le conflit est
    # noté dans l'historique avec la référence de TELEDEC).
    #
    # Adresse des rappels donnée à TELEDEC (`auth.url`) : sous `base_url`
    # (`https://dossier.exemple.fr`) si elle est donnée, sinon sous
    # l'adresse publique de l'instance (`Callbacks.instance_base_url`,
    # tirée de ses réglages, jamais de la requête) ; `https://` seulement.
    # Sans elle, le suivi se fait par `refresh`.
    def self.transmit(actor : Actor, id : Int64, base_url : String? = nil) : Result(FilingView)
      Guard.authorize!(actor, TRANSMIT, module_code: MODULE_CODE)
      filing = find(id)
      authorize_sources!(actor, filing.kind.to_s)
      return status_failure(filing) unless filing.status == "prepared"
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
      found = Filings.credentials(Settings.current!)
      return Result(FilingView).failure(found.errors) if found.failure?
      credentials = found.value!

      # Clé d'idempotence : dépôt, rang de la transmission (un dépôt rejeté
      # puis préparé de nouveau est un nouvel envoi), empreinte.
      fingerprint = filing.fingerprint.to_s
      attempt = FilingEvent.filter(filing_id: filing.id, status: "transmitted").count + 1
      year_end = filing.fiscal_year_id.try { |year_id| Builder.find_fiscal_year(year_id.to_i64) }.try(&.ends_on)
      submission = Submission.new("partiduo-#{filing.id}-#{attempt}-#{fingerprint[0, 16]}", filing.kind.to_s,
        filing.forms.to_s.split(','), filing.payload.to_s, fingerprint, due_on: filing.due_on.try { |day| Builder.day(day) },
        year_end: year_end.try { |day| Builder.day(day) }, callback_url: Callbacks.url(base_url || Callbacks.instance_base_url))
      submitted = begin
        transport.submit(credentials, submission)
      rescue ex : TransportError
        note_error(id, ex.key, actor, event: true)
        return Result(FilingView).failure(FieldError.base(ex.key, ex.params))
      end
      Filings.note_account(credentials.env) if submitted.account_created
      remote_id = submitted.remote_id
      recorded = Partiduo::Api::Transaction.run do
        Filings.lock!
        current = find(id)
        unless current.status == "prepared" && current.fingerprint == fingerprint
          next Result(FilingView).failure(FieldError.base("teledec.errors.filing.concurrent", {"reference" => remote_id}))
        end
        current.status = "transmitted"
        current.remote_id = remote_id
        current.remote_reference = submission.reference
        current.remote_url = submitted.url
        current.remote_status = submitted.remote_status
        current.declaration_id = ""
        current.last_error = ""
        current.transmitted_at = Time.utc
        current.transmitted_by_id = actor.user_id
        current.save!
        Filings.event(current, "transmitted", remote_id, actor.user_id)
        Result(FilingView).success(Filings.view(current))
      end
      if recorded.failure?
        # Envoi fait, mais le dépôt a changé entre-temps : trace de l'envoi.
        Partiduo::Api::Transaction.run do
          Filings.lock!
          current = find(id)
          Filings.event(current, "error", I18n.t("teledec.errors.filing.concurrent", {"reference" => remote_id}), actor.user_id)
          Result(Nil).success(nil)
        end
      end
      recorded
    end

    # Interroge TELEDEC sur un dépôt transmis : accusé de réception
    # (conservé en pièce jointe du socle) ou rejet (motif).
    def self.refresh(actor : Actor, id : Int64) : Result(FilingView)
      Guard.authorize!(actor, TRANSMIT, module_code: MODULE_CODE)
      filing = find(id)
      return status_failure(filing) if filing.status != "transmitted" || filing.manual
      transport = Transports.current || return Result(FilingView).failure(FieldError.base("teledec.errors.transport.unavailable"))
      found = Filings.credentials(Settings.current!)
      return Result(FilingView).failure(found.errors) if found.failure?
      remote_id = filing.remote_id.to_s
      remote = begin
        transport.status(found.value!, remote_id, filing.remote_reference.to_s)
      rescue ex : TransportError
        note_error(id, ex.key, actor, event: false)
        return Result(FilingView).failure(FieldError.base(ex.key, ex.params))
      end
      attachment = remote.receipt.try do |receipt|
        Partiduo::Api::Core::AttachmentInput.new(receipt.filename, receipt.content_type, IO::Memory.new(receipt.content))
      end
      Partiduo::Api::Transaction.run do
        Filings.lock!
        current = find(id)
        if current.status != "transmitted" || current.manual || current.remote_id != remote_id
          next status_failure(current)
        end
        current.remote_status = remote.remote_status[0, 32] unless remote.remote_status.empty?
        current.declaration_id = remote.declaration_id[0, 64] unless remote.declaration_id.empty?
        current.last_error = ""
        unless remote.state == "acknowledged" || remote.state == "rejected"
          current.save!
          next Result(FilingView).success(Filings.view(current))
        end
        apply_outcome(current, remote.state, remote.reason, attachment, remote.at, actor)
      end
    end

    # Interroge TELEDEC sur tous les dépôts transmis ; rend le nombre de
    # dépôts dont le statut a changé. Chaque dépôt est isolé : l'erreur de
    # l'un (identifiants illisibles, panne) n'interrompt pas les autres.
    def self.refresh_all(actor : Actor) : Int32
      Guard.authorize!(actor, TRANSMIT, module_code: MODULE_CODE)
      return 0 unless Transports.available?
      Filing.filter(status: "transmitted", manual: false).to_a.count do |filing|
        result = refresh(actor, filing.id!.to_i64)
        result.success? && result.value!.status != "transmitted"
      rescue ex : Partiduo::Api::Forbidden | Partiduo::Api::ModuleDisabled
        raise ex
      rescue ex
        Log.warn(exception: ex) { "TELEDEC : suivi du dépôt #{filing.id} interrompu" }
        false
      end
    end

    # Rappel de TELEDEC (webhook, `POST` de `Callbacks::PATH`) : pas
    # d'acteur, l'appel est authentifié par le mot de passe des rappels du
    # partenaire, en `Basic` (`authorization` : en-tête `Authorization`).
    # Rend `unauthorized`, `invalid` (corps illisible), `ignored` (aucun
    # dépôt ne correspond) ou `ok` ; idempotent sur l'identifiant de la
    # déclaration. `ModuleDisabled` si l'extension est inactive.
    def self.callback(authorization : String?, body : String) : String
      raise Partiduo::Api::ModuleDisabled.new(MODULE_CODE) unless Callbacks.active?
      return "unauthorized" unless Callbacks.authenticate(authorization)
      Callbacks.receive(body)
    end

    # Note l'issue d'un dépôt fait hors de Partiduo (repli : balance
    # importée sur le site de TELEDEC) : transmis, accusé (pièce jointe
    # facultative) ou rejeté (motif obligatoire). Une seule transaction,
    # sous le verrou des dépôts : une pièce refusée annule tout (le dépôt
    # reste préparé).
    def self.record_outcome(actor : Actor, id : Int64, input : OutcomeInput) : Result(FilingView)
      Guard.authorize!(actor, TRANSMIT, module_code: MODULE_CODE)
      find(id)
      Partiduo::Api::Transaction.run do
        Filings.lock!
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
        next Result(FilingView).failure(errors) unless errors.empty?

        # La pièce est remise telle quelle au socle, qui borne la lecture
        # (`Attachments::MAX_BYTES`).
        attachment = nil
        if (io = input.receipt) && (name = input.receipt_filename.presence)
          attachment = Partiduo::Api::Core::AttachmentInput.new(name, input.receipt_content_type || "application/pdf", io)
        end
        if filing.status == "prepared"
          filing.manual = true
          filing.remote_id = input.reference.strip[0, 128]
          filing.transmitted_at = Time.utc
          filing.transmitted_by_id = actor.user_id
          filing.status = "transmitted"
          filing.save!
          Filings.event(filing, "transmitted", I18n.t("teledec.events.manual"), actor.user_id)
          next Result(FilingView).success(Filings.view(filing)) if input.status == "transmitted"
        end
        apply_outcome(filing, input.status == "acknowledged" ? "acknowledged" : "rejected", input.reason.strip, attachment, nil, actor)
      end
    end

    # --- Fichiers ----------------------------------------------------------------

    # Balance de l'exercice au format d'import courant (repli, ADR-007 D5).
    # `AccountingRequired` sans la Comptabilité.
    def self.balance_file(actor : Actor, fiscal_year_id : Int64) : FileView
      Guard.authorize!(actor, PREPARE, module_code: MODULE_CODE)
      raise AccountingRequired.new unless Sources.accounting?
      authorize_sources!(actor, "liasse")
      fiscal_year = Builder.find_fiscal_year(fiscal_year_id) || raise Partiduo::Api::NotFound.new("fiscal_year", fiscal_year_id)
      ends_on = fiscal_year.ends_on
      raise Partiduo::Api::NotFound.new("fiscal_year", fiscal_year_id) if fiscal_year.starts_on.nil? || ends_on.nil?
      siren = Partiduo::Api::Core.settings(Actor.system).siren.delete(' ').presence || "000000000"
      content = Balance.csv(Balance.compute(fiscal_year))
      FileView.new("#{siren}-balance-#{ends_on.to_s("%Y%m%d")}.csv", "text/csv; charset=utf-8",
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

    # Droits sur les sources de la déclaration. Sans la Comptabilité, aucune
    # garde de la Comptabilité n'est citée : la liasse (2035) exige la
    # lecture du livre-journal de `liberal`, les autres sortes sont
    # refusées ensuite par `Builder` (`teledec.errors.accounting_required`).
    private def self.authorize_sources!(actor : Actor, kind : String) : Nil
      unless Sources.accounting?
        Guard.authorize!(actor, "liberal.register.read", module_code: Sources::LIBERAL) if kind == "liasse"
        return
      end
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

    # SIRET des paramètres : vide, ou 14 chiffres commençant par le SIREN de
    # la société (SIRET d'un de ses établissements).
    private def self.siret_error(siret : String) : FieldError?
      return if siret.empty?
      return FieldError.new("siret", "teledec.errors.credentials.siret") unless siret.matches?(/\A\d{14}\z/)
      siren = Partiduo::Api::Core.settings(Actor.system).siren.delete(' ')
      return if siren.empty? || siret.starts_with?(siren)
      FieldError.new("siret", "teledec.errors.credentials.siret_siren", {"siren" => siren})
    end

    private def self.status_failure(filing : Filing) : Result(FilingView)
      Result(FilingView).failure(FieldError.base("teledec.errors.filing.status",
        {"status" => I18n.t("teledec.statuses.#{filing.status}")}))
    end

    # Note l'erreur du transport sur le dépôt relu sous verrou (seules
    # `last_error` et l'historique changent).
    private def self.note_error(id : Int64, key : String, actor : Actor, event : Bool) : Nil
      Partiduo::Api::Transaction.run do
        Filings.lock!
        current = find(id)
        current.last_error = key
        current.save!
        Filings.event(current, "error", key, actor.user_id) if event
        Result(Nil).success(nil)
      end
      nil
    end

    # Accusé ou rejet d'un dépôt transmis (`Filings.apply_outcome`).
    private def self.apply_outcome(filing : Filing, state : String, reason : String,
                                   attachment : Partiduo::Api::Core::AttachmentInput?, at : Time?,
                                   actor : Actor) : Result(FilingView)
      Filings.apply_outcome(filing, state, reason, attachment, at, actor.user_id)
    end

    private def self.settings_view(settings : Settings, manager : Bool) : SettingsView
      accounting = Sources.accounting?
      tax_system = Sources.tax_system(settings, accounting)
      SettingsView.new(
        tax_system: tax_system,
        vat_system: settings.vat_system.to_s,
        greffe: settings.greffe || false,
        das2_accounts: Filings.das2_accounts(settings),
        das2_threshold: settings.das2_threshold || Config::DAS2_THRESHOLD,
        env: settings.env.to_s,
        login: manager ? settings.login.to_s : "",
        email: manager ? settings.email.to_s : "",
        siret: manager ? settings.siret.to_s : "",
        callback_path: manager ? Callbacks::PATH : "",
        callback_url: manager ? Callbacks.url.to_s : "",
        callback_password: Callbacks.configured?,
        account_email: manager ? Filings.account_address.to_s : "",
        key_stored: !settings.api_key.to_s.empty?,
        checked_at: settings.checked_at,
        transport: Transports.current.try(&.name),
        forms: Config::FORMS[tax_system]? || [] of String,
        accounting: accounting,
        kinds: Sources.kinds(tax_system, accounting),
        tax_systems: Sources.tax_systems(accounting),
      )
    end
  end
end
