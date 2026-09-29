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
  #   haché bcrypt du mot de passe ; créé par la liasse (`#EMAIL`,
  #   `#MOT-DE-PASSE`) ou, avant la première déclaration en marque blanche,
  #   par `POST /service/creation-entreprise`.
  #
  # Les identifiants et le jeton ne sont jamais journalisés ni rendus ;
  # les erreurs sont des clés i18n (`teledec.errors.transport.*`) avec le
  # message de TELEDEC pour motif. Le greffe ne se dépose pas par l'API
  # (parcours de redirection en marque blanche dont les routes ne sont pas
  # documentées, D-TDC3-008) : `teledec.errors.transport.greffe`.
  class HttpTransport < Transport
    AUTH_URL       = "https://auth.partners.teledec.fr/oauth2/token"
    API_URLS       = {"sandbox" => "https://stage.teledec.fr", "production" => "https://www.teledec.fr"}
    SCOPE_PREFIXES = {"sandbox" => "stage", "production" => "prod"}
    SCOPES         = %w[liasse marque-blanche declaration-status liste-cr creation-entreprise]
    # Marge avant l'expiration du jeton.
    TOKEN_MARGIN = 60.seconds
    # Source déclarée dans la liasse : `API`, valeur donnée par TELEDEC
    # (réponses du 29 septembre 2026, D-TDC3-001) ; réglable par
    # `PARTIDUO_TELEDEC_SOURCE`.
    DEFAULT_SOURCE = "API"

    record Token, value : String, expires_at : Time

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

    @tokens = {} of String => Token
    @mutex = Mutex.new

    def initialize(@exchange : Remote::Exchange = Remote::Net.new, @name : String = "TELEDEC",
                   source : String? = nil, @send_button : Bool = true, @clock : Proc(Time) = -> { Time.utc },
                   user_domain : String? = nil, user_format : String? = nil)
      @source = source || ENV["PARTIDUO_TELEDEC_SOURCE"]?.presence || DEFAULT_SOURCE
      @user_domain = Remote::Account.domain(user_domain || ENV[Remote::Account::DOMAIN_VARIABLE]?)
      @user_format = Remote::Account.format(user_format || ENV[Remote::Account::FORMAT_VARIABLE]?)
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
      raise TransportError.new("teledec.errors.transport.greffe") if payload.kind == "greffe"
      account = account_email(payload.identity.siren)
      require_password!(credentials)
      key = Remote::Formats.key(payload, submission.due_on)
      if payload.kind == "liasse"
        # TELEDEC rattache la liasse à l'entreprise par son SIRET ; la
        # liasse crée le compte de l'entreprise s'il n'existe pas.
        raise TransportError.new("teledec.errors.transport.siret") unless Remote::Formats.siret(credentials, payload.identity)
        body = Remote::Formats.liasse(payload, submission, credentials, source, send_button?, account)
        response = call(credentials, "POST", "/service/liasse", body, "text/plain; charset=utf-8")
        return Submitted.new(key.to_s, link(response.body), "notcompleted", account_created: true)
      end
      created = false
      unless credentials.account_ready
        year_end = submission.year_end.try { |day| Time.parse(day, "%F", Time::Location::UTC) } ||
                   Time.utc(Time.parse(payload.period_to, "%F", Time::Location::UTC).year, 12, 31)
        create_company(credentials, Remote::Formats.company_identity(payload, credentials, year_end),
          credentials.password_hash, account)
        created = true
      end
      body = Remote::Formats.white_label(payload, submission, credentials, @clock.call, account)
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
      return RemoteStatus.new("pending", remote_status: "notfound") if response.status == 404
      answer = parse_object(response.body)
      raw = answer["status"]?.try { |value| value.as_s? || value.raw.to_s } || ""
      state = Remote::Formats.state(raw)
      normalized = Remote::Formats.normalize(raw)
      return RemoteStatus.new("pending", remote_status: normalized) if state == "pending"
      listed = (answer["compteRendus"]?.try(&.as_a?) || [] of JSON::Any).map { |item| Remote::Formats.report(item) }
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
        remote_status: normalized, declaration_id: report.try(&.declaration_id) || "")
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

    # --- HTTP -------------------------------------------------------------------

    private def call(credentials : Credentials, method : String, path : String, body : String = "",
                     content_type : String? = nil, allow : Array(Int32) = [] of Int32) : Remote::Response
      base = API_URLS[credentials.env]? || raise TransportError.new("teledec.errors.credentials.env")
      response = nil
      2.times do |attempt|
        headers = HTTP::Headers{"Authorization" => "Bearer #{token(credentials).value}", "Accept" => "application/json, text/plain"}
        content_type.try { |type| headers["Content-Type"] = type }
        response = @exchange.call(Remote::Request.new(method, "#{base}#{path}", headers, body))
        break unless response.status == 401 && attempt == 0
        forget(credentials)
      end
      response = response.as(Remote::Response)
      return response if response.ok? || allow.includes?(response.status)
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

    private def request_token(credentials : Credentials) : Token
      prefix = SCOPE_PREFIXES[credentials.env]? || raise TransportError.new("teledec.errors.credentials.env")
      basic = Base64.strict_encode("#{credentials.login}:#{credentials.api_key}")
      headers = HTTP::Headers{"Authorization" => "Basic #{basic}", "Content-Type" => "application/x-www-form-urlencoded",
                              "Accept" => "application/json"}
      body = URI::Params.build do |form|
        form.add "grant_type", "client_credentials"
        form.add "scope", SCOPES.map { |scope| "#{prefix}/#{scope}" }.join(' ')
      end
      response = @exchange.call(Remote::Request.new("POST", AUTH_URL, headers, body))
      if response.status.in?(400, 401, 403)
        raise TransportError.new("teledec.errors.transport.credentials")
      end
      raise TransportError.new("teledec.errors.transport.unreachable") unless response.ok?
      answer = parse_object(response.body)
      value = answer["access_token"]?.try(&.as_s?) || raise TransportError.new("teledec.errors.transport.credentials")
      lifetime = answer["expires_in"]?.try { |item| item.as_i64? || item.as_s?.try(&.to_i64?) } || 3600_i64
      Token.new(value, Time.utc + lifetime.seconds - TOKEN_MARGIN)
    end

    # --- Outils -----------------------------------------------------------------

    # Haché bcrypt du mot de passe du compte (`Filings.credentials` le crée
    # à la première transmission).
    private def require_password!(credentials : Credentials) : Nil
      raise TransportError.new("teledec.errors.transport.password") unless credentials.password_hash.starts_with?("$2")
    end

    # Adresse rendue par l'API Balance : texte brut, ou JSON (`url`,
    # `lien`).
    private def link(body : String) : String
      text = body.strip
      if text.starts_with?('{')
        answer = parse_object(text)
        return (answer["url"]? || answer["lien"]?).try(&.as_s?) || ""
      end
      text.starts_with?("http") ? text.lines.first.strip : ""
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
