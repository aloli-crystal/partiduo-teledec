# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"
require "base64"
require "digest/sha256"

module Teledec
  # Adaptateur réel de l'API partenaire de TELEDEC (ADR-007 D4, D5).
  #
  # * Jeton OAuth2 `client_credentials` (`POST
  #   https://auth.partners.teledec.fr/oauth2/token`, identifiants du client
  #   en `Basic`, scopes `stage/…` ou `prod/…` selon l'environnement),
  #   gardé en cache une heure (moins une minute de marge) ; un 401 le
  #   renouvelle et rejoue l'appel une fois.
  # * Liasse par l'API Balance (`POST /service/liasse`) : TELEDEC ventile la
  #   balance dans les formulaires et rend l'adresse de la liasse, que
  #   l'utilisateur ouvre pour vérifier et envoyer.
  # * TVA CA3 et CA12, DAS2, relevés 2571 et 2572 par l'API marque blanche
  #   (`POST /service/declaration-marque-blanche`), lien de la déclaration
  #   demandé (`retournerLien`).
  # * Suivi par `/service/declaration-status` puis, pour un dépôt accepté ou
  #   rejeté, par les comptes-rendus (`compteRendus` du suivi, sinon
  #   `/service/recuperation-liste-compterendus`) : accusé en PDF, erreurs
  #   de la DGFiP.
  #
  # * Compte de l'entreprise en marque blanche (`Remote::Account`) : adresse
  #   dans le domaine du partenaire (`PARTIDUO_TELEDEC_USER_DOMAIN`,
  #   obligatoire : sans lui, `teledec.errors.transport.user_domain`) et
  #   haché bcrypt du mot de passe ; créé avant le premier dépôt (liasse
  #   ou marque blanche) par `POST /service/creation-entreprise`, avec le
  #   régime fiscal du dossier (D-TDC5-002) ; la liasse porte aussi
  #   `#EMAIL` et `#MOT-DE-PASSE`.
  #
  # * Validation locale facultative (`PARTIDUO_TELEDEC_SCHEMAS_DIR` :
  #   dossier des schémas JSON officiels de TELEDEC, `Remote::Schemas`) :
  #   chaque document est validé *dans l'instance*, avant l'envoi, contre le
  #   schéma de son formulaire au bon millésime (l'enveloppe seule si le
  #   formulaire n'a pas de schéma, un avertissement journalisé alors) ; un
  #   écart refuse l'envoi (`teledec.errors.transport.schema`, chemin JSON
  #   cité). Sans réglage, rien ne change (D-TDC6-003). TELEDEC n'offre
  #   aucune validation sans dépôt (pas de « dry-run », réponses du
  #   1er octobre 2026, D-TDC9-006) : seule cette validation locale existe.
  #
  # * Greffe (réponses du 1er octobre 2026, D-TDC9-001, D-TDC9-002) :
  #   amorce par `POST /service/nouvelle-declaration` (droit
  #   `nouvelle-declaration` du jeton, `formulaire: "greffe"`) pour une
  #   forme juridique qui dépose ses comptes (`Config.greffe_eligible?`) ;
  #   TELEDEC rend l'adresse de redirection (connexion automatique) où
  #   l'utilisateur finalise le dépôt. Suivi par `declaration-status`
  #   (`formulaire=greffe`) ; dès que le dépôt est finalisé, son PDF signé
  #   se relève par `GET /service/declarationPdf/{token}/…` (`document`),
  #   le jeton venant de `lienPdf` des retours.
  #
  # Les identifiants et le jeton ne sont jamais journalisés ni rendus ;
  # les erreurs sont des clés i18n (`teledec.errors.transport.*`) avec le
  # message de TELEDEC pour motif.
  class HttpTransport < Transport
    AUTH_URL       = "https://auth.partners.teledec.fr/oauth2/token"
    API_URLS       = {"sandbox" => "https://stage.teledec.fr", "production" => "https://www.teledec.fr"}
    SCOPE_PREFIXES = {"sandbox" => "stage", "production" => "prod"}
    SCOPES         = %w[liasse marque-blanche declaration-status liste-cr creation-entreprise nouvelle-declaration]
    # Droits demandés seulement s'ils sont accordés : un client qui ne les
    # a pas encore (refus `invalid_scope` du service des jetons) reçoit un
    # jeton sans eux, et seul le dépôt qui les exige est refusé
    # (`teledec.errors.transport.scope`).
    OPTIONAL_SCOPES = %w[nouvelle-declaration]
    # Droit de l'amorce du dépôt au greffe.
    GREFFE_SCOPE = "nouvelle-declaration"
    # Marge avant l'expiration du jeton.
    TOKEN_MARGIN = 60.seconds
    # Source déclarée dans la liasse : `API`, valeur donnée par TELEDEC
    # (réponses du 29 septembre 2026, D-TDC3-001) ; réglable par
    # `PARTIDUO_TELEDEC_SOURCE`.
    DEFAULT_SOURCE = "API"

    # Jeton et droits qu'il porte (sans préfixe d'environnement).
    record Token, value : String, expires_at : Time, scopes : Array(String) = SCOPES

    getter exchange : Remote::Exchange
    property source : String
    # Bouton « Envoyer » de la liasse chez TELEDEC (l'utilisateur envoie
    # lui-même à la DGFiP après vérification).
    property? send_button : Bool
    # Heure de l'horodatage de la marque blanche (réglable pour les specs).
    property clock : Proc(Time)
    # Domaine des adresses des comptes en marque blanche (défaut :
    # `PARTIDUO_TELEDEC_USER_DOMAIN`) et format de leur partie locale
    # (défaut : `PARTIDUO_TELEDEC_USER_FORMAT`, sinon `teledec-{siren}`) ;
    # `nil` si le réglage manque ou est invalide.
    property user_domain : String?
    property user_format : String?
    # Schémas JSON de TELEDEC (défaut : `PARTIDUO_TELEDEC_SCHEMAS_DIR`) ;
    # `nil` : aucune validation avant l'envoi.
    property schemas : Remote::Schemas?
    # Clé de l'adresse des rappels dans la liasse (`#URL` par défaut,
    # `PARTIDUO_TELEDEC_LIASSE_CALLBACK_KEY`, D-TDC9-004).
    property liasse_callback_key : String

    @tokens = {} of String => Token
    @mutex = Mutex.new

    def initialize(@exchange : Remote::Exchange = Remote::Net.new, @name : String = "TELEDEC",
                   source : String? = nil, @send_button : Bool = true, @clock : Proc(Time) = -> { Time.utc },
                   user_domain : String? = nil, user_format : String? = nil, schemas_dir : String? = nil,
                   liasse_callback_key : String? = nil)
      @source = source || ENV["PARTIDUO_TELEDEC_SOURCE"]?.presence || DEFAULT_SOURCE
      @liasse_callback_key = Remote::Formats.liasse_callback_key(liasse_callback_key || ENV[Remote::Formats::LIASSE_CALLBACK_VARIABLE]?)
      @user_domain = Remote::Account.domain(user_domain || ENV[Remote::Account::DOMAIN_VARIABLE]?)
      @user_format = Remote::Account.format(user_format || ENV[Remote::Account::FORMAT_VARIABLE]?)
      @schemas = Remote::Schemas.from(schemas_dir || ENV[Remote::Schemas::VARIABLE]?)
    end

    # Adresse du compte de l'entreprise de SIREN `siren` chez TELEDEC ;
    # `teledec.errors.transport.user_domain` si le domaine du partenaire
    # n'est pas réglé (ou le format invalide).
    def account_email(siren : String) : String
      Remote::Account.email(siren, @user_domain, @user_format) ||
        raise TransportError.new("teledec.errors.transport.user_domain")
    end

    def name : String
      @name
    end

    def check(credentials : Credentials) : Nil
      forget(credentials)
      token(credentials)
      nil
    end

    def submit(credentials : Credentials, submission : Submission) : Submitted
      payload = begin
        Payload.from_json(submission.payload)
      rescue JSON::ParseException | JSON::SerializableError
        raise TransportError.new("teledec.errors.transport.invalid")
      end
      account = account_email(payload.identity.siren)
      require_password!(credentials)
      key = Remote::Formats.key(payload, submission.due_on)
      return greffe(credentials, payload, submission, account, key) if payload.kind == "greffe"
      if payload.kind == "liasse"
        # TELEDEC rattache la liasse à l'entreprise par son SIRET. La liasse
        # ne crée pas le compte de l'entreprise : sur le stage, le suivi
        # d'une liasse déposée pour une entreprise sans compte répond
        # « Utilisateur non trouvé » ; il est créé avant, comme pour la
        # marque blanche (D-TDC5-002).
        raise TransportError.new("teledec.errors.transport.siret") unless Remote::Formats.siret(credentials, payload.identity)
        validate_zones!(payload)
        created = ensure_company(credentials, payload, submission, account)
        body = Remote::Formats.liasse(payload, submission, credentials, source, send_button?, account, liasse_callback_key)
        response = call(credentials, "POST", "/service/liasse", body, "text/plain; charset=utf-8")
        return Submitted.new(key.to_s, Remote::Formats.redirect_url(response.body), "notcompleted", account_created: created)
      end
      body = Remote::Formats.white_label(payload, submission, credentials, @clock.call, account)
      validate_document!(payload, submission, body)
      created = ensure_company(credentials, payload, submission, account)
      response = call(credentials, "POST", "/service/declaration-marque-blanche", body, "application/json")
      answer = parse_object(response.body)
      if message = answer["message"]?.try(&.as_s?)
        raise TransportError.new("teledec.errors.transport.refused", {"reason" => short(message)})
      end
      Submitted.new(key.to_s, answer["lien"]?.try(&.as_s?) || "", "readytobesent", account_created: created)
    end

    def status(credentials : Credentials, remote_id : String, reference : String = "") : RemoteStatus
      key = Remote::Formats::Key.parse(remote_id) || raise TransportError.new("teledec.errors.transport.invalid")
      account = account_email(key.siren)
      params = URI::Params.build do |form|
        form.add "email", account
        form.add "siren", key.siren
        form.add "date_fin", key.date_fin
        form.add "formulaire", key.form
        key.echeance.try { |day| form.add "date_echeance", day }
      end
      response = call(credentials, "GET", "/service/declaration-status?#{params}", allow: [404])
      # Dépôt pas encore trouvé (404) : jamais une erreur. Sur le stage, une
      # DAS2 ou une liasse acceptée reste introuvable par le suivi juste
      # après le dépôt, quels que soient le délai et les paramètres
      # (D-TDC11-002) : en attente de finalisation chez TELEDEC, depuis son
      # lien ; le suivi la relira plus tard.
      return RemoteStatus.new("pending", remote_status: "notfound") if response.status == 404
      answer = parse_object(response.body)
      raw = answer["status"]?.try { |value| value.as_s? || value.raw.to_s } || ""
      state = Remote::Formats.state(raw)
      normalized = Remote::Formats.normalize(raw)
      listed = (answer["compteRendus"]?.try(&.as_a?) || [] of JSON::Any).map { |item| Remote::Formats.report(item) }
      if state == "pending"
        document = greffe_document(credentials, key, raw, answer, listed)
        return RemoteStatus.new("pending", remote_status: normalized, document: document)
      end
      listed = reports(credentials, key) if listed.empty?
      # Comptes-rendus de cette déclaration et de cet envoi : de son type
      # (un paiement ne vaut que pour un relevé d'IS), pas d'un envoi
      # précédent (autre référence, après un rejet puis un nouvel envoi :
      # l'ancien ERREUR ne vaut pas pour le nouveau).
      kind = Remote::Formats.kind_of_form(key.form)
      reports = listed.select { |item| Remote::Formats.concerns?(item, kind) && !item.stale?(reference) }
      return RemoteStatus.new("pending") if reports.empty? && !listed.empty?
      report = Remote::Formats.latest(reports)
      reason = report.try(&.reason).presence || answer["message"]?.try(&.as_s?).to_s
      receipt = report.try(&.pdf).try do |pdf|
        Receipt.new("#{state == "acknowledged" ? "accuse" : "rejet"}-#{key.form}-#{key.siren}-#{key.date_fin}.pdf",
          "application/pdf", pdf)
      end
      RemoteStatus.new(state, reason: reason, receipt: receipt, at: report.try(&.at),
        remote_status: normalized, declaration_id: report.try(&.declaration_id) || "",
        document: greffe_document(credentials, key, raw, answer, reports))
    end

    # PDF d'un dépôt finalisé chez TELEDEC
    # (`GET /service/declarationPdf/{token}/teledec-liasse-fiscale.pdf`,
    # réponses du 1er octobre 2026) : `token` vient de `lienPdf` des retours
    # (`Formats.pdf_token`) ; la route est toujours celle de l'environnement
    # des identifiants. Un corps qui n'est pas un PDF, ou un refus :
    # `teledec.errors.transport.document`.
    def document(credentials : Credentials, token : String, name : String) : Receipt
      response = begin
        call(credentials, "GET", Remote::Formats.pdf_path(token), accept: "application/pdf")
      rescue ex : TransportError
        raise ex if ex.key == "teledec.errors.transport.unreachable"
        raise TransportError.new("teledec.errors.transport.document", {"reason" => ex.params["reason"]? || ex.key})
      end
      unless response.body.starts_with?("%PDF")
        raise TransportError.new("teledec.errors.transport.document", {"reason" => "PDF attendu"})
      end
      Receipt.new(name, "application/pdf", response.body.to_slice)
    end

    # Nom du PDF du dépôt au greffe conservé dans les pièces jointes.
    def self.document_name(key : Remote::Formats::Key) : String
      "depot-greffe-#{key.siren}-#{key.date_fin}.pdf"
    end

    # PDF signé d'un dépôt au greffe finalisé (état brut `raw` : envoyé,
    # accepté ou rejeté), si un retour porte son lien (`lienPdf` de la
    # réponse du suivi ou d'un compte-rendu) ; `nil` sinon, et pour toute
    # autre sorte de dépôt.
    private def greffe_document(credentials : Credentials, key : Remote::Formats::Key, raw : String,
                                answer : Hash(String, JSON::Any), reports : Array(Remote::Formats::Report)) : Receipt?
      return unless key.form == "greffe" && Remote::Formats.finalized?(raw)
      links = [answer["lienPdf"]?.try(&.as_s?).to_s] + reports.map(&.pdf_link)
      token = links.compact_map { |link| Remote::Formats.pdf_token(link) }.first? || return
      document(credentials, token, HttpTransport.document_name(key))
    end

    # Comptes-rendus d'un dépôt (`/service/recuperation-liste-compterendus`) ;
    # liste vide si TELEDEC n'en a pas (404).
    def reports(credentials : Credentials, key : Remote::Formats::Key) : Array(Remote::Formats::Report)
      params = URI::Params.build do |form|
        form.add "siren", key.siren
        form.add "dateFin", key.date_fin
        form.add "formulaire", key.form
        key.echeance.try { |day| form.add "date_echeance", day }
        form.add "email", account_email(key.siren)
      end
      response = call(credentials, "GET", "/service/recuperation-liste-compterendus?#{params}", allow: [404])
      return [] of Remote::Formats::Report if response.status == 404
      parsed = parse(response.body)
      list = parsed.as_a? || parsed["compteRendus"]?.try(&.as_a?) || [] of JSON::Any
      list.map { |item| Remote::Formats.report(item) }
    end

    # Amorce du dépôt au greffe (`POST /service/nouvelle-declaration`,
    # D-TDC9-001) : forme juridique éligible, droit `nouvelle-declaration`
    # dans le jeton, entreprise créée chez TELEDEC ; rend l'adresse de
    # redirection (connexion automatique) que l'utilisateur ouvre pour
    # finaliser le dépôt.
    private def greffe(credentials : Credentials, payload : Payload, submission : Submission, account : String,
                       key : Remote::Formats::Key) : Submitted
      unless Config.greffe_eligible?(payload.identity.legal_form)
        raise TransportError.new("teledec.errors.transport.greffe_legal_form")
      end
      require_scope!(credentials, GREFFE_SCOPE)
      created = ensure_company(credentials, payload, submission, account)
      body = Remote::Formats.greffe(payload, submission, credentials, @clock.call, account)
      response = call(credentials, "POST", "/service/nouvelle-declaration", body, "application/json",
        denied: {"teledec.errors.transport.scope", {"scope" => GREFFE_SCOPE}})
      url = Remote::Formats.redirect_url(response.body)
      if url.empty?
        message = message_of(response.body)
        raise TransportError.new("teledec.errors.transport.no_link") if message.blank? || message.strip.starts_with?('{')
        raise TransportError.new("teledec.errors.transport.refused", {"reason" => short(message)})
      end
      Submitted.new(key.to_s, url, "notcompleted", account_created: created)
    end

    # Droit `scope` absent du jeton : `teledec.errors.transport.scope`.
    private def require_scope!(credentials : Credentials, scope : String) : Nil
      return if token(credentials).scopes.includes?(scope)
      raise TransportError.new("teledec.errors.transport.scope", {"scope" => scope})
    end

    # Crée ou met à jour l'entreprise chez TELEDEC et la rattache au compte
    # `account` (`POST /service/creation-entreprise`) ; `password_hash` :
    # haché bcrypt (coût 12) du mot de passe du compte. Appelé avant la
    # première déclaration en marque blanche d'un dossier (D-TDC3-007).
    def create_company(credentials : Credentials, identity : Hash(String, String | Int32), password_hash : String,
                       account : String) : String
      raise TransportError.new("teledec.errors.transport.password") unless password_hash.starts_with?("$2")
      body = {"auth" => {"email" => account, "password" => password_hash}, "identity" => identity}.to_json
      call(credentials, "POST", "/service/creation-entreprise", body, "application/json").body
    end

    # Crée l'entreprise et son compte chez TELEDEC avant son premier dépôt
    # (`credentials.account_ready` faux) ; rend vrai s'il vient d'être
    # créé.
    private def ensure_company(credentials : Credentials, payload : Payload, submission : Submission,
                               account : String) : Bool
      return false if credentials.account_ready
      year_end = submission.year_end.try { |day| Time.parse(day, "%F", Time::Location::UTC) } ||
                 Time.utc(Time.parse(payload.period_to, "%F", Time::Location::UTC).year, 12, 31)
      create_company(credentials, Remote::Formats.company_identity(payload, credentials, year_end),
        credentials.password_hash, account)
      true
    end

    # --- Validation par les schémas de TELEDEC ----------------------------------

    # Document de la marque blanche validé contre le schéma de son
    # formulaire au millésime visé (D-TDC6-003) ; sans schéma du
    # formulaire, l'enveloppe seule, avec un avertissement.
    private def validate_document!(payload : Payload, submission : Submission, body : String) : Nil
      store = usable_schemas || return
      form = Remote::Formats.form_key(payload.kind) || return
      target = Remote::Formats.millesime_target(payload, submission.due_on)
      outcome = store.check_document(JSON.parse(body), form, target)
      warn_missing(outcome, target) unless outcome.millesime
      refuse!(outcome)
    end

    # Cases jointes à la liasse (`zones_formulaires`) validées bloc par
    # bloc contre le schéma de leur formulaire ; le texte de la balance
    # n'a pas de schéma.
    private def validate_zones!(payload : Payload) : Nil
      store = usable_schemas || return
      zones = Remote::Formats.liasse_zones(payload) || return
      target = Remote::Formats.millesime_target(payload)
      zones.each do |form, values|
        outcome = store.check_block(form, JSON.parse(values.to_json), target)
        warn_missing(outcome, target) unless outcome.checked
        refuse!(outcome)
      end
    end

    # Schémas réglés et présents ; un dossier réglé mais absent est signalé
    # (rien n'est validé).
    private def usable_schemas : Remote::Schemas?
      store = @schemas || return
      return store if store.present?
      Log.warn { "TELEDEC : dossier des schémas introuvable (#{Remote::Schemas::VARIABLE}=#{store.dir}), aucune validation" }
      nil
    end

    private def warn_missing(outcome : Remote::Schemas::Outcome, target : Int32) : Nil
      what = outcome.checked ? "enveloppe seule validée" : "document non validé"
      Log.warn { "TELEDEC : pas de schéma #{outcome.form} au millésime #{target} ni avant (#{what})" }
    end

    # Refus traduit du premier écart, chemin JSON cité ; le nombre des
    # autres suit.
    private def refuse!(outcome : Remote::Schemas::Outcome) : Nil
      first = outcome.violations.first? || return
      problem = I18n.t("teledec.schema.#{first.code}", first.params)
      others = outcome.violations.size - 1
      more = others.zero? ? "" : I18n.t("teledec.schema.more", {"count" => others.to_s})
      raise TransportError.new("teledec.errors.transport.schema", {"schema" => outcome.schema_name,
                                                                   "path" => first.path, "problem" => problem, "more" => more})
    end

    # --- HTTP -------------------------------------------------------------------

    # `denied` : erreur rendue pour un 401 ou 403 persistant (droit absent
    # du jeton pour cette route), au lieu de `credentials`.
    private def call(credentials : Credentials, method : String, path : String, body : String = "",
                     content_type : String? = nil, allow : Array(Int32) = [] of Int32,
                     accept : String = "application/json, text/plain",
                     denied : {String, Hash(String, String)}? = nil) : Remote::Response
      base = API_URLS[credentials.env]? || raise TransportError.new("teledec.errors.credentials.env")
      response = nil
      2.times do |attempt|
        headers = HTTP::Headers{"Authorization" => "Bearer #{token(credentials).value}", "Accept" => accept}
        content_type.try { |type| headers["Content-Type"] = type }
        response = @exchange.call(Remote::Request.new(method, "#{base}#{path}", headers, body))
        break unless response.status == 401 && attempt == 0
        forget(credentials)
      end
      response = response.as(Remote::Response)
      return response if response.ok? || allow.includes?(response.status)
      if denied && response.status.in?(401, 403)
        raise TransportError.new(denied[0], denied[1])
      end
      raise error(response)
    end

    # Erreur de TELEDEC traduite en clé i18n, avec son message pour motif.
    private def error(response : Remote::Response) : TransportError
      message = message_of(response.body)
      case response.status
      when 401, 403
        TransportError.new("teledec.errors.transport.credentials")
      else
        if source_refused?(message)
          TransportError.new("teledec.errors.transport.source", {"reason" => short(message)})
        elsif message.downcase.includes?("utilisateur non trouv")
          TransportError.new("teledec.errors.transport.account", {"reason" => short(message)})
        elsif response.status >= 500 && message.downcase.includes?("erreur technique")
          TransportError.new("teledec.errors.transport.unreachable")
        else
          TransportError.new("teledec.errors.transport.refused", {"reason" => short(message)})
        end
      end
    end

    # Refus de la source de la liasse (`#SOURCE`), tel que TELEDEC le
    # formule (erreur 101 : « il manque la source ou la source n'est pas un
    # partenaire reconnu ») : « la source » ou « source non reconnue », en
    # mots entiers. Ni la sous-chaîne « source » (« Ressource
    # introuvable »), ni toute erreur 101 (email invalide, par exemple).
    private def source_refused?(message : String) : Bool
      message.downcase.matches?(/\bla source\b|\bsource (non|pas) reconnue\b/)
    end

    private def message_of(body : String) : String
      parsed = JSON.parse(body)
      if hash = parsed.as_h?
        %w[message erreur error_description error].each do |name|
          hash[name]?.try(&.as_s?).try { |text| return text }
        end
      end
      body
    rescue JSON::ParseException
      body
    end

    # --- Jeton ------------------------------------------------------------------

    private def cache_key(credentials : Credentials) : String
      "#{credentials.env}:#{credentials.login}:#{Digest::SHA256.hexdigest(credentials.api_key)[0, 16]}"
    end

    private def forget(credentials : Credentials) : Nil
      @mutex.synchronize { @tokens.delete(cache_key(credentials)) }
      nil
    end

    private def token(credentials : Credentials) : Token
      key = cache_key(credentials)
      if cached = @mutex.synchronize { @tokens[key]? }
        return cached if cached.expires_at > Time.utc
      end
      fresh = request_token(credentials)
      @mutex.synchronize { @tokens[key] = fresh }
      fresh
    end

    # Jeton portant tous les droits (`SCOPES`) ; si le service des jetons
    # refuse un droit facultatif (`invalid_scope`), jeton sans eux.
    private def request_token(credentials : Credentials) : Token
      prefix = SCOPE_PREFIXES[credentials.env]? || raise TransportError.new("teledec.errors.credentials.env")
      response = token_response(credentials, prefix, SCOPES)
      requested = SCOPES
      if response.status == 400 && invalid_scope?(response.body)
        requested = SCOPES - OPTIONAL_SCOPES
        response = token_response(credentials, prefix, requested)
      end
      if response.status.in?(400, 401, 403)
        raise TransportError.new("teledec.errors.transport.credentials")
      end
      raise TransportError.new("teledec.errors.transport.unreachable") unless response.ok?
      answer = parse_object(response.body)
      value = answer["access_token"]?.try(&.as_s?) || raise TransportError.new("teledec.errors.transport.credentials")
      lifetime = answer["expires_in"]?.try { |item| item.as_i64? || item.as_s?.try(&.to_i64?) } || 3600_i64
      Token.new(value, Time.utc + lifetime.seconds - TOKEN_MARGIN, granted(answer, prefix, requested))
    end

    private def token_response(credentials : Credentials, prefix : String, scopes : Array(String)) : Remote::Response
      basic = Base64.strict_encode("#{credentials.login}:#{credentials.api_key}")
      headers = HTTP::Headers{"Authorization" => "Basic #{basic}", "Content-Type" => "application/x-www-form-urlencoded",
                              "Accept" => "application/json"}
      body = URI::Params.build do |form|
        form.add "grant_type", "client_credentials"
        form.add "scope", scopes.map { |scope| "#{prefix}/#{scope}" }.join(' ')
      end
      @exchange.call(Remote::Request.new("POST", AUTH_URL, headers, body))
    end

    private def invalid_scope?(body : String) : Bool
      JSON.parse(body)["error"]?.try(&.as_s?) == "invalid_scope"
    rescue JSON::ParseException | TypeCastError
      body.includes?("invalid_scope")
    end

    # Droits du jeton : ceux que le service des jetons annonce (`scope`),
    # sinon ceux demandés.
    private def granted(answer : Hash(String, JSON::Any), prefix : String, requested : Array(String)) : Array(String)
      announced = answer["scope"]?.try(&.as_s?) || return requested
      announced.split(' ').compact_map(&.lchop?("#{prefix}/"))
    end

    # --- Outils -----------------------------------------------------------------

    # Haché bcrypt du mot de passe du compte (`Filings.credentials` le crée
    # à la première transmission).
    private def require_password!(credentials : Credentials) : Nil
      raise TransportError.new("teledec.errors.transport.password") unless credentials.password_hash.starts_with?("$2")
    end

    private def parse(body : String) : JSON::Any
      JSON.parse(body)
    rescue JSON::ParseException
      raise TransportError.new("teledec.errors.transport.invalid")
    end

    private def parse_object(body : String) : Hash(String, JSON::Any)
      parse(body).as_h? || raise TransportError.new("teledec.errors.transport.invalid")
    end

    private def short(text : String) : String
      clean = text.gsub(/\s+/, " ").strip
      clean.size > 300 ? "#{clean[0, 300]}…" : clean
    end
  end
end
