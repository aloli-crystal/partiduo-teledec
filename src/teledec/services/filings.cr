# SPDX-License-Identifier: AGPL-3.0-or-later

module Teledec
  # Dépôts : enregistrement d'une préparation, transitions de statut,
  # historique, vues. Interne : appelé par `Teledec::Api`, qui contrôle les
  # droits.
  module Filings
    alias FieldError = Partiduo::Api::FieldError
    alias ControlView = Api::ControlView

    LOCK = "teledec_filing"

    def self.settings : Settings
      Settings.current!
    end

    # Comptes de la DAS2 (préfixe → nature) : paramètres, sinon défaut.
    def self.das2_accounts(settings : Settings) : Hash(String, String)
      text = settings.das2_accounts.to_s
      return Config::DAS2_ACCOUNTS.dup if text.empty?
      Hash(String, String).from_json(text)
    rescue JSON::ParseException
      Config::DAS2_ACCOUNTS.dup
    end

    # Acomptes d'IS (2571) transmis ou accusés pour l'exercice.
    def self.corporate_tax_advances(fiscal_year_id : Int64) : BigDecimal
      Filing.filter(kind: "is_2571", fiscal_year_id: fiscal_year_id, status__in: %w[transmitted acknowledged]).to_a
        .sum(Money::ZERO) { |filing| Money.parse(Payload.from_json(filing.payload.to_s).details["amount"]? || "0") }
    end

    # Enregistre la préparation (nouveau dépôt, ou dépôt préparé ou rejeté
    # remis à jour). Refus si le dépôt est transmis ou accusé.
    def self.save(built : Builder::Built, user_id : Int64?) : Partiduo::Api::Result(Filing)
      Partiduo::Api::Transaction.run do
        lock!
        filing = Filing.filter(key: built.key).first
        if filing && !%w[prepared rejected].includes?(filing.status)
          next Partiduo::Api::Result(Filing).failure(FieldError.base("teledec.errors.filing.locked",
            {"status" => I18n.t("teledec.statuses.#{filing.status}")}))
        end
        now = Time.utc
        filing ||= Filing.new(key: built.key)
        filing.kind = built.kind
        filing.forms = built.forms.join(",")
        filing.fiscal_year_id = built.fiscal_year_id
        filing.year = built.year
        filing.number = built.number
        filing.period_from = built.period_from
        filing.period_to = built.period_to
        filing.due_on = built.due_on
        filing.vat_return_id = built.vat_return_id
        filing.status = "prepared"
        filing.payload = built.payload.to_json
        filing.fingerprint = built.payload.fingerprint
        filing.controls = built.controls.to_json
        filing.remote_id = ""
        filing.remote_reference = ""
        filing.remote_status = ""
        filing.remote_url = ""
        filing.declaration_id = ""
        filing.rejection_reason = ""
        filing.last_error = ""
        filing.manual = false
        filing.prepared_at = now
        filing.prepared_by_id = user_id
        filing.transmitted_at = nil
        filing.transmitted_by_id = nil
        filing.rejected_at = nil
        # Pièce du rejet noté à la main : elle reste dans les pièces jointes
        # du socle, mais n'est pas l'accusé du nouveau dépôt (de même pour
        # le PDF d'un dépôt au greffe rejeté).
        filing.receipt_attachment_id = nil
        filing.document_attachment_id = nil
        filing.acknowledged_at = nil
        filing.save!
        event(filing, "prepared", "", user_id)
        Partiduo::Api::Result(Filing).success(filing)
      end
    end

    def self.event(filing : Filing, status : String, detail : String, user_id : Int64?) : Nil
      FilingEvent.create!(filing_id: filing.id, status: status, detail: detail[0, 2000], user_id: user_id, created_at: Time.utc)
      nil
    end

    # Verrou consultatif de transaction : une préparation ou une
    # transmission à la fois.
    def self.lock! : Nil
      Marten::DB::Connection.default.open do |db|
        db.exec("SELECT pg_advisory_xact_lock(hashtext($1))", LOCK)
      end
      nil
    end

    def self.controls(filing : Filing) : Array(ControlView)
      Array(ControlView).from_json(filing.controls.to_s.presence || "[]")
    end

    # Identifiants de l'API : échec `credentials.missing` s'il n'y en a pas,
    # `credentials.unreadable` si la clé enregistrée ne se déchiffre plus
    # (clé de l'instance changée, valeur altérée). Crée au besoin le haché
    # du mot de passe du compte de l'entreprise chez TELEDEC (D-TDC3-007).
    def self.credentials(settings : Settings) : Partiduo::Api::Result(Credentials)
      key = settings.api_key.to_s
      if settings.login.to_s.empty? || key.empty?
        return Partiduo::Api::Result(Credentials).failure(FieldError.base("teledec.errors.credentials.missing"))
      end
      api_key = Secrets.decrypt(key)
      hash = account_password_hash
      env = settings.env.to_s
      Partiduo::Api::Result(Credentials).success(Credentials.new(settings.login.to_s, api_key, env,
        account_email(settings.email.to_s), settings.siret.to_s, password_hash: hash,
        account_ready: settings.account_env.to_s == env))
    rescue Secrets::Error
      Partiduo::Api::Result(Credentials).failure(FieldError.base("teledec.errors.credentials.unreadable"))
    end

    # Haché bcrypt du mot de passe du compte de l'entreprise chez TELEDEC,
    # créé une fois (sous le verrou des dépôts) ; le mot de passe lui-même
    # n'est jamais gardé.
    def self.account_password_hash : String
      current = Settings.current!.account_password_hash.to_s
      return current unless current.empty?
      created = ""
      Partiduo::Api::Transaction.run do
        lock!
        settings = Settings.current!
        if settings.account_password_hash.to_s.empty?
          settings.account_password_hash = Remote::Account.new_password_hash
          settings.save!
        end
        created = settings.account_password_hash.to_s
        Partiduo::Api::Result(Nil).success(nil)
      end
      created
    end

    # Note que le compte de l'entreprise existe chez TELEDEC dans
    # l'environnement `env` (plus de création avant la marque blanche).
    def self.note_account(env : String) : Nil
      Partiduo::Api::Transaction.run do
        lock!
        settings = Settings.current!
        settings.account_env = env
        settings.save!
        Partiduo::Api::Result(Nil).success(nil)
      end
      nil
    end

    # Adresse du compte de l'entreprise chez TELEDEC selon le transport
    # branché (domaine du partenaire), `nil` si elle ne peut être formée.
    def self.account_address : String?
      transport = Transports.current.as?(HttpTransport) || return
      siren = Partiduo::Api::Core.settings(Builder.system).siren.delete(' ')
      Remote::Account.email(siren, transport.user_domain, transport.user_format)
    rescue Partiduo::Api::NotFound
      nil
    end

    # Email du compte TELEDEC : celui des paramètres, sinon celui de la
    # société.
    def self.account_email(email : String) : String
      email.presence || Partiduo::Api::Core.settings(Builder.system).email.strip
    rescue Partiduo::Api::NotFound
      email
    end

    # Accusé ou rejet d'un dépôt transmis. Appelé dans une transaction qui
    # tient le verrou des dépôts, sur le dépôt relu (`Api.refresh`,
    # `Api.record_outcome`, rappels de TELEDEC) ; une pièce refusée par le
    # socle annule le tout.
    def self.apply_outcome(filing : Filing, state : String, reason : String,
                           attachment : Partiduo::Api::Core::AttachmentInput?, at : Time?,
                           user_id : Int64?) : Partiduo::Api::Result(Api::FilingView)
      return Partiduo::Api::Result(Api::FilingView).success(view(filing)) unless state == "acknowledged" || state == "rejected"
      Partiduo::Api::Transaction.run do
        if attachment
          stored = Partiduo::Api::Core.store_attachment(Partiduo::Api::Actor.system, attachment)
          next Partiduo::Api::Result(Api::FilingView).failure(stored.errors) if stored.failure?
          filing.receipt_attachment_id = stored.value!.id
        end
        if state == "acknowledged"
          filing.status = "acknowledged"
          filing.acknowledged_at = at || Time.utc
          event(filing, "acknowledged", attachment.try(&.filename) || "", user_id)
        else
          filing.status = "rejected"
          filing.rejection_reason = reason.presence || I18n.t("teledec.events.no_reason")
          filing.rejected_at = at || Time.utc
          event(filing, "rejected", filing.rejection_reason.to_s, user_id)
          # 2035 rejetée : l'exercice du module `liberal` redevient
          # modifiable, sauf clôture (D-LIB2-003).
          TaxReturns.rejected(filing, user_id)
        end
        filing.last_error = ""
        filing.save!
        Partiduo::Api::Result(Api::FilingView).success(view(filing))
      end
    end

    # Conserve le PDF signé d'un dépôt au greffe en pièce jointe du socle
    # (`document_attachment_id`), une fois : un PDF déjà conservé n'est pas
    # remplacé. Appelé dans une transaction qui tient le verrou des dépôts ;
    # rend l'échec du socle s'il refuse la pièce.
    def self.store_document(filing : Filing, document : Receipt, user_id : Int64?) : Array(FieldError)
      return [] of FieldError unless filing.document_attachment_id.nil?
      input = Partiduo::Api::Core::AttachmentInput.new(document.filename, document.content_type,
        IO::Memory.new(document.content))
      stored = Partiduo::Api::Core.store_attachment(Partiduo::Api::Actor.system, input)
      return stored.errors if stored.failure?
      filing.document_attachment_id = stored.value!.id
      event(filing, filing.status.to_s, I18n.t("teledec.events.document", {"filename" => document.filename}), user_id)
      [] of FieldError
    end

    # --- Vues ------------------------------------------------------------------

    def self.view(filing : Filing) : Api::FilingView
      payload = Payload.from_json(filing.payload.to_s)
      balance = (payload.balance || [] of Payload::BalanceRow).map do |row|
        Api::BalanceRowView.new(row.account, row.label, Money.parse(row.debit), Money.parse(row.credit),
          Money.parse(row.balance_debit), Money.parse(row.balance_credit))
      end
      boxes = (payload.boxes || {} of String => Hash(String, String)).flat_map do |form, values|
        values.map { |box, amount| Api::BoxView.new(form, box, Money.parse(amount)) }
      end
      das2 = (payload.das2 || [] of Payload::Das2Line).map do |line|
        address = [line.address, "#{line.postcode} #{line.city}".strip].reject(&.blank?).join(", ")
        born = line.birth_date.presence.try { |day| Time.parse(day, "%F", Time::Location::UTC) }
        Api::Das2LineView.new(line.card_code, line.name, line.siret, address,
          line.amounts.transform_values { |value| Money.parse(value) }, Money.parse(line.total),
          line.person?, line.last_name, line.first_names, born)
      end
      Api::FilingView.new(
        id: filing.id!.to_i64,
        key: filing.key.to_s,
        kind: filing.kind.to_s,
        forms: filing.forms.to_s.split(',').reject(&.empty?),
        fiscal_year_id: filing.fiscal_year_id.try(&.to_i64),
        year: filing.year!.to_i32,
        number: filing.number!.to_i32,
        period_from: filing.period_from!,
        period_to: filing.period_to!,
        due_on: filing.due_on,
        vat_return_id: filing.vat_return_id.try(&.to_i64),
        status: filing.status.to_s,
        fingerprint: filing.fingerprint.to_s,
        controls: controls(filing),
        company_name: payload.identity.company_name,
        siren: payload.identity.siren,
        balance: balance,
        previous_balance_rows: payload.previous_balance.try(&.size) || 0,
        boxes: boxes,
        das2: das2,
        details: payload.details,
        remote_id: filing.remote_id.to_s,
        remote_status: filing.remote_status.to_s,
        remote_url: filing.remote_url.to_s,
        declaration_id: filing.declaration_id.to_s,
        manual: filing.manual || false,
        rejection_reason: filing.rejection_reason.to_s,
        last_error: filing.last_error.to_s,
        receipt_attachment_id: filing.receipt_attachment_id.try(&.to_i64),
        document_attachment_id: filing.document_attachment_id.try(&.to_i64),
        prepared_at: filing.prepared_at!,
        transmitted_at: filing.transmitted_at,
        acknowledged_at: filing.acknowledged_at,
        rejected_at: filing.rejected_at,
      )
    end

    # En-tête d'un dépôt, sans relire le document (listes).
    def self.summary(filing : Filing) : Api::FilingSummaryView
      Api::FilingSummaryView.new(
        id: filing.id!.to_i64,
        key: filing.key.to_s,
        kind: filing.kind.to_s,
        forms: filing.forms.to_s.split(',').reject(&.empty?),
        fiscal_year_id: filing.fiscal_year_id.try(&.to_i64),
        year: filing.year!.to_i32,
        number: filing.number!.to_i32,
        period_from: filing.period_from!,
        period_to: filing.period_to!,
        due_on: filing.due_on,
        status: filing.status.to_s,
        controls: controls(filing),
        remote_id: filing.remote_id.to_s,
        manual: filing.manual || false,
        prepared_at: filing.prepared_at!,
        transmitted_at: filing.transmitted_at,
        acknowledged_at: filing.acknowledged_at,
        rejected_at: filing.rejected_at,
      )
    end

    def self.events(filing_id : Int64) : Array(Api::EventView)
      FilingEvent.filter(filing_id: filing_id).order(:id).to_a.map do |row|
        Api::EventView.new(row.status.to_s, row.detail.to_s, row.user_id.try(&.to_i64), row.created_at!)
      end
    end

    # --- Échéances -------------------------------------------------------------

    # Échéances de l'exercice. Sans la Comptabilité, la liasse 2035 seule
    # (régime BNC), sans lecture des déclarations de TVA de la Comptabilité
    # (DECISIONS D-TDC2-003).
    def self.schedule(fiscal_year : Partiduo::Api::Core::FiscalYearView) : Array(Api::DeadlineView)
      starts_on = fiscal_year.starts_on || return [] of Api::DeadlineView
      ends_on = fiscal_year.ends_on || starts_on
      settings = self.settings
      accounting = Sources.accounting?
      tax_system = Sources.tax_system(settings, accounting)
      filings = Filing.filter(fiscal_year_id: fiscal_year.id).to_a.index_by(&.key.to_s)
      filings.merge!(Filing.filter(key: "das2:#{ends_on.year}").to_a.index_by(&.key.to_s))
      deadlines = [] of Api::DeadlineView
      add = ->(key : String, kind : String, number : Int32, from : Time, to : Time, due : Time, vat_id : Int64?) do
        filing = filings[key]?
        deadlines << Api::DeadlineView.new(key, kind, Config.forms(kind, tax_system), fiscal_year.id,
          kind == "das2" ? to.year : ends_on.year, number, from, to, due, vat_id, filing.try(&.id!.to_i64), filing.try(&.status))
        nil
      end
      if accounting || !Sources.needs_accounting?("liasse", tax_system)
        add.call("liasse:#{fiscal_year.id}", "liasse", 0, starts_on, ends_on, Calendar.liasse(ends_on), nil)
      end
      return deadlines unless accounting
      if Config::CORPORATE_TAX_SYSTEMS.includes?(tax_system)
        Calendar.corporate_tax_advances(starts_on, ends_on).each_with_index(1) do |due, number|
          add.call("is_2571:#{fiscal_year.id}:#{number}", "is_2571", number, starts_on, ends_on, due, nil)
        end
        add.call("is_2572:#{fiscal_year.id}", "is_2572", 0, starts_on, ends_on, Calendar.corporate_tax_balance(ends_on), nil)
      end
      vat_deadlines(settings.vat_system.to_s, starts_on, ends_on).each do |(kind, from, to, due, number)|
        key = "#{kind}:#{Builder.day(from)}"
        add.call(key, kind, number, from, to, due, closed_vat_return(kind, from, to))
      end
      das2_from = Time.utc(ends_on.year, 1, 1)
      add.call("das2:#{ends_on.year}", "das2", 0, das2_from, Time.utc(ends_on.year, 12, 31), Calendar.das2(ends_on.year), nil)
      # Greffe : option active et forme juridique qui dépose ses comptes
      # (D-TDC9-001).
      if settings.greffe && Config.greffe_eligible?(Partiduo::Api::Core.settings(Builder.system).legal_form)
        add.call("greffe:#{fiscal_year.id}", "greffe", 0, starts_on, ends_on, Calendar.greffe(ends_on), nil)
      end
      deadlines.sort_by! { |item| {item.due_on, item.key} }
    end

    private def self.vat_deadlines(system : String, starts_on : Time, ends_on : Time) : Array({String, Time, Time, Time, Int32})
      case system
      when "ca3_monthly", "ca3_quarterly"
        months = system == "ca3_monthly" ? 1 : 3
        Calendar.vat_periods(starts_on, ends_on, months).map do |(from, to)|
          {"vat_ca3", from, to, Calendar.vat_monthly(to), months == 1 ? from.month : (from.month - 1) // 3 + 1}
        end
      when "ca12"
        [{"vat_ca12", starts_on, ends_on, Calendar.vat_annual(ends_on), 1}]
      else
        [] of {String, Time, Time, Time, Int32}
      end
    end

    # Déclaration de TVA close de la Comptabilité pour la période (même
    # début), sinon `nil`.
    private def self.closed_vat_return(kind : String, from : Time, to : Time) : Int64?
      form = kind == "vat_ca3" ? "fr_ca3" : "fr_ca12"
      years = (from.year..to.year).to_a
      years.each do |year|
        found = Partiduo::Api::Accounting.vat_returns(Builder.system, form, year).find do |item|
          item.closed? && item.date_from == from
        end
        return found.id if found
      end
      nil
    end
  end
end
