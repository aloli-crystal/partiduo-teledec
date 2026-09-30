# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"
require "base64"

module Teledec
  # TELEDEC simulé pour les specs et les vérifications (ADR-007 D4) :
  # l'adaptateur réel (`Teledec::HttpTransport`) branché sur un serveur en
  # mémoire (`Server`) qui reproduit les échanges de l'API partenaire —
  # jeton OAuth2 (`Basic`, scopes, expiration, 401), API Balance
  # (identification `#CLE valeur`, balance à huit colonnes, source
  # reconnue, URL rendue), marque blanche (horodatage de moins d'une heure,
  # lien rendu, formulaire principal du régime exigé à son millésime), suivi
  # (`declaration-status`, comptes-rendus, 404 sans déclaration, compte
  # inconnu), création d'entreprise (mot de passe bcrypt ; seule à créer le
  # compte)
  # et corps des rappels. Aucun appel réseau. Domaine des comptes en marque
  # blanche : `partiduo.test` (fictif, jamais résolu).
  class SimulatedTeledec < HttpTransport
    LOGIN   = "cabinet-test"
    API_KEY = "cle-de-test-0123456789"
    # Email de contact et SIRET de l'entreprise des specs (SIREN
    # 732 829 320) ; domaine fictif des comptes en marque blanche et compte
    # de l'entreprise des specs chez TELEDEC.
    EMAIL       = "compta@atelier-brunet.test"
    SIRET       = "73282932000074"
    USER_DOMAIN = "partiduo.test"
    ACCOUNT     = "teledec-732829320@partiduo.test"

    getter server : Server

    def initialize(server : Server = Server.new, user_domain : String? = USER_DOMAIN)
      @server = server
      super(server, name: "TELEDEC simulé", source: Server::SOURCE, user_domain: user_domain)
      # Sans domaine demandé, aucun : l'adaptateur doit refuser.
      @user_domain = nil if user_domain.nil?
    end

    delegate deposits, failure, acknowledge, reject, reject_with_errors, callback_body, expire_tokens!,
      token_requests, requests, accounts, to: @server

    def failure=(reason : String?) : String?
      @server.failure = reason
    end

    def calls : Int32
      @server.requests.size
    end

    # Serveur simulé : reçoit les requêtes de l'adaptateur.
    class Server < Remote::Exchange
      SOURCE = "API"
      BASE   = {"stage.teledec.fr" => "stage", "www.teledec.fr" => "prod"}
      PDF    = "%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n"
      # Formulaires principaux qui identifient le régime de l'entreprise
      # (annexe G de la page marque blanche, DAS2 comprise) : un dépôt en
      # marque blanche sans aucun d'eux est refusé, avec le message du
      # stage. Un formulaire ne compte qu'à partir de son premier millésime
      # (`FIRST_MILLESIMES`) : le stage a refusé ainsi une DAS2 envoyée au
      # millésime 2025, qui n'a pas de DAS2 (DECISIONS D-TDC6-001).
      REGIME_FORMS = %w[3310CA3 3517SCA12 3514 2571 2572 3519 DAS2 2072S 2031 2035 2036 1329AC 1329DEF 2065 2257
        2258]
      FIRST_MILLESIMES = {"DAS2" => 2026}
      NO_REGIME_FORM   = "aucun formulaire de TVA ou de paiement ou de liasse n'a été trouvé dans le message envoyé " \
                         "depuis votre logiciel de comptabilité. Un des formulaires principaux permettant " \
                         "l'identification du régime de l'entreprise n'est pas présent, veuillez en saisir un dans " \
                         "votre payload. ISRN : 3310CA3, 3514, 3519…"
      UNKNOWN_USER = "Utilisateur non trouvé pour l'email fourni"

      # Déclaration reçue : clé de suivi (`<formulaire>:<siren>:<fin>[:<échéance>]`),
      # sorte (`liasse` ou formulaire de la marque blanche), référence du
      # partenaire, corps reçu, environnement, compte, état, compte-rendu.
      class Deposit
        getter remote_id : String
        getter form : String
        property reference : String
        property body : String
        getter env : String
        getter email : String
        getter declaration_id : Int64
        property status : String
        property callback_url : String?
        property report : Hash(String, JSON::Any)?

        def initialize(@remote_id, @form, @reference, @body, @env, @email, @declaration_id, @status, @callback_url = nil)
        end

        # Document marque blanche reçu (JSON), `nil` pour une liasse.
        def json : JSON::Any?
          body.starts_with?('{') ? JSON.parse(body) : nil
        end
      end

      record Token, value : String, prefix : String, expires_at : Time

      getter deposits = {} of String => Deposit
      getter requests = [] of Remote::Request
      getter token_requests = 0
      # Comptes d'entreprise créés (adresse → haché bcrypt du mot de passe).
      getter accounts = {} of String => String
      # Motif de refus programmé de la prochaine déclaration.
      property failure : String? = nil
      # `false` : le suivi ne joint pas les comptes-rendus (l'adaptateur les
      # relève par `/service/recuperation-liste-compterendus`).
      property? reports_in_status : Bool = true
      @tokens = {} of String => Token
      @next_id = 285_900_i64

      def call(request : Remote::Request) : Remote::Response
        @requests << request
        uri = request.uri
        return token(request) if request.url == HttpTransport::AUTH_URL
        prefix = BASE[uri.host.to_s]? || return text(404, "hôte inconnu")
        if denied = authenticate(request, prefix)
          return denied
        end
        case {request.method, uri.path}
        when {"POST", "/service/liasse"}                         then liasse(request, prefix)
        when {"POST", "/service/declaration-marque-blanche"}     then white_label(request, prefix)
        when {"GET", "/service/declaration-status"}              then status(request)
        when {"GET", "/service/recuperation-liste-compterendus"} then reports(request)
        when {"POST", "/service/creation-entreprise"}            then company(request)
        else                                                          text(404, "Not Found")
        end
      end

      # Tous les jetons délivrés expirent (le suivant répondra 401).
      def expire_tokens! : Nil
        @tokens.transform_values! { |item| Token.new(item.value, item.prefix, Time.utc - 1.second) }
        nil
      end

      # Accusé de réception de la DGFiP (état `OK`, accusé en PDF).
      def acknowledge(remote_id : String) : Nil
        deposit = deposits[remote_id]
        deposit.status = "OK"
        deposit.report = report(deposit, "OK", "Accepted", {"pdf" => JSON::Any.new(Base64.strict_encode(PDF))})
      end

      # Rejet de la DGFiP, motif en `erreurLibelle`.
      def reject(remote_id : String, reason : String) : Nil
        deposit = deposits[remote_id]
        deposit.status = "ERREUR"
        deposit.report = report(deposit, "ERREUR", "Rejected", {"erreurCode"    => JSON::Any.new(""),
                                                                "erreurLibelle" => JSON::Any.new(reason)})
      end

      # Rejet avec les erreurs de la DGFiP (`declarationErreurs`).
      def reject_with_errors(remote_id : String, errors : Array(Hash(String, String))) : Nil
        deposit = deposits[remote_id]
        deposit.status = "ERREUR"
        list = errors.map { |error| JSON::Any.new(error.transform_values { |value| JSON::Any.new(value) }) }
        deposit.report = report(deposit, "ERREUR", "Rejected", {"declarationErreurs" => JSON::Any.new(list)})
      end

      # Corps du rappel (callback) que TELEDEC posterait pour ce dépôt.
      def callback_body(remote_id : String) : String
        deposit = deposits[remote_id]
        (deposit.report || report(deposit, deposit.status, "Sent", {} of String => JSON::Any)).to_json
      end

      # --- Routes -----------------------------------------------------------------

      private def token(request : Remote::Request) : Remote::Response
        @token_requests += 1
        basic = request.headers["Authorization"]?.to_s.lchop("Basic ")
        login, _, secret = (String.new(Base64.decode(basic)) rescue "").partition(':')
        unless login == LOGIN && secret == API_KEY
          return json(401, {"error" => "invalid_client"})
        end
        params = URI::Params.parse(request.body)
        return json(400, {"error" => "unsupported_grant_type"}) unless params["grant_type"]? == "client_credentials"
        scopes = params["scope"]?.to_s.split(' ').reject(&.empty?)
        prefixes = scopes.map(&.split('/').first).uniq!
        return json(400, {"error" => "invalid_scope"}) unless prefixes.size == 1 && BASE.values.includes?(prefixes.first)
        value = "sim-#{@token_requests}-#{Random::Secure.hex(8)}"
        @tokens[value] = Token.new(value, prefixes.first, Time.utc + 1.hour)
        json(200, {"access_token" => value, "expires_in" => 3600, "token_type" => "Bearer"})
      end

      private def authenticate(request : Remote::Request, prefix : String) : Remote::Response?
        header = request.headers["Authorization"]?.to_s
        return text(401, "The token was expected to have 3 parts, but got 1.") unless header.starts_with?("Bearer ")
        token = @tokens[header.lchop("Bearer ")]? || return text(401, "The token was expected to have 3 parts, but got 1.")
        return text(401, "The Token has expired.") if token.expires_at < Time.utc
        return text(401, "The Token scope does not match.") unless token.prefix == prefix
        nil
      end

      private def liasse(request : Remote::Request, prefix : String) : Remote::Response
        fields = {} of String => String
        rows = 0
        # Section JSON : de la première ligne qui commence par `{` à la fin
        # du corps, un seul objet (forme de la documentation, D-TDC7-001).
        head, brace, rest = request.body.partition(/^\{/m)
        zones = false
        unless brace.empty?
          section = (JSON.parse(brace + rest).as_h? rescue nil)
          return text(500, "Misformatted JSON") unless section && section["zones_formulaires"]?.try(&.as_h?)
          zones = true
        end
        head.each_line do |line|
          if line.starts_with?('#')
            name, _, value = line.lchop('#').partition(' ')
            fields[name] = value.strip
          elsif !line.strip.empty?
            cells = line.split(';')
            unless cells.size == 8 && cells[2..].all?(&.matches?(/\A-?\d+(\.\d+)?\z/))
              return text(500, "erreur 102 : ligne de balance invalide : #{line}")
            end
            rows += 1
          end
        end
        unless fields["SOURCE"]? == SOURCE
          return text(500, "erreur 101 : format de la liasse non reconnu (format Unknown: format teledec : il manque " \
                           "la source ou la source n'est pas un partenaire reconnu par TELEDEC).")
        end
        email = fields["EMAIL"]?.to_s
        return text(500, "erreur 101 : format de la liasse non reconnu (format Unknown: format teledec : l'email renseigné '#{email}' est invalide.).") unless email.matches?(/\A[^@\s]+@[^@\s]+\z/)
        siret = fields["SIRET"]?.to_s
        finish = fields["EXERCICE-DATE-FIN"]?.to_s
        return text(500, "erreur technique interne") unless siret.matches?(/\A\d{14}\z/) && finish.matches?(/\A\d{8}\z/)
        # La liasse ne crée pas le compte de l'entreprise (constaté sur le
        # stage : suivi « Utilisateur non trouvé » après la liasse d'une
        # entreprise sans compte, D-TDC5-002).
        if password = fields["MOT-DE-PASSE"]?
          return text(500, "erreur 101 : mot de passe non chiffré") unless password.starts_with?("$2")
        end
        # Liasse sans balance (2035 d'un libéral sans Comptabilité, D-TDC2-002) :
        # admise si elle porte des zones de formulaires (supposé, B-TDC-004).
        return text(500, "erreur 104 : balance vide") if rows.zero? && !zones
        if reason = failure
          return text(500, "erreur 104 : #{reason}")
        end
        remote_id = "liasse:#{siret[0, 9]}:#{finish[0, 4]}-#{finish[4, 2]}-#{finish[6, 2]}"
        deposit = store(remote_id, "liasse", fields["REFERENCE"]?.to_s, request.body, prefix, email, "NotCompleted", nil)
        text(200, "https://#{prefix == "stage" ? "stage" : "www"}.teledec.fr/liasse/#{deposit.declaration_id}")
      end

      private def white_label(request : Remote::Request, prefix : String) : Remote::Response
        document = JSON.parse(request.body).as_h rescue return json(400, {"message" => "JSON invalide"})
        auth = document["auth"]?.try(&.as_h?) || return json(400, {"message" => "auth absent"})
        email = auth["email"]?.try(&.as_s?).to_s
        return json(400, {"message" => "email absent"}) if email.empty?
        stamp = auth["timestamp"]?.try(&.as_s?).to_s
        at = (Time.parse(stamp, "%Y-%m-%dT%H:%M:%S", Remote::Formats::PARIS) rescue nil)
        now = Time.utc
        return json(400, {"message" => "timestamp invalide"}) if at.nil? || at > now + 5.minutes || at < now - 1.hour
        identity = document["identity"]?.try(&.as_h?) || return json(400, {"message" => "identity absent"})
        period = document["period"]?.try(&.as_h?) || return json(400, {"message" => "period absent"})
        form = (Remote::Formats::FORM_KEYS.values - ["liasse"]).find { |name| document.has_key?(name) } ||
               return json(400, {"message" => "formulaire absent"})
        return json(400, {"message" => NO_REGIME_FORM}) unless regime_form?(document, period)
        if form == "DAS2" && (invalid = das2_invalid(document["DAS2"]))
          return json(400, {"message" => invalid})
        end
        return json(400, {"message" => failure.to_s}) if failure
        siren = identity["siret"]?.try(&.as_s?).to_s[0, 9]
        finish = period["end"]?.try(&.as_s?).to_s
        echeance = period["echeance"]?.try(&.as_s?)
        remote_id = "#{form}:#{siren}:#{finish}"
        remote_id += ":#{echeance}" if echeance && form.in?("2571", "3310CA3", "3517SCA12")
        deposit = store(remote_id, form, period["reference"]?.try(&.as_s?).to_s, request.body, prefix, email,
          "readyToBeSent", auth["url"]?.try(&.as_s?))
        if auth["retournerLien"]?.try(&.as_bool?)
          json(200, {"lien" => "https://#{prefix == "stage" ? "stage" : "www"}.teledec.fr/service/declaration/#{deposit.declaration_id}"})
        else
          json(200, {"status" => "ok"})
        end
      end

      private def status(request : Remote::Request) : Remote::Response
        params = request.query_params
        return text(400, UNKNOWN_USER) unless accounts.has_key?(params["email"]?.to_s)
        deposit = lookup(params["formulaire"]?, params["siren"]?, params["date_fin"]?, params["date_echeance"]?)
        return text(400, UNKNOWN_USER) if deposit && deposit.email != params["email"]?
        return json(404, {"message" => "declaration not found", "status" => "ERREUR"}) unless deposit
        answer = {"status" => JSON::Any.new(deposit.status)}
        if reports_in_status?
          deposit.report.try { |report| answer["compteRendus"] = JSON::Any.new([JSON::Any.new(report)]) }
        end
        Remote::Response.new(200, answer.to_json, "application/json")
      end

      private def reports(request : Remote::Request) : Remote::Response
        params = request.query_params
        deposit = lookup(params["formulaire"]?, params["siren"]?, params["dateFin"]?, params["date_echeance"]?)
        report = deposit.try(&.report) || return json(404, {"message" => "declaration not found", "status" => "ERREUR"})
        Remote::Response.new(200, [report].to_json, "application/json")
      end

      private def company(request : Remote::Request) : Remote::Response
        document = JSON.parse(request.body).as_h rescue return text(400, "JSON invalide")
        auth = document["auth"]?.try(&.as_h?) || return text(400, "auth absent")
        unless auth["password"]?.try(&.as_s?).to_s.starts_with?("$2")
          return text(400, "Password du compte absent ou format d'encryption différent de celui attendu")
        end
        accounts[auth["email"]?.try(&.as_s?).to_s] = auth["password"].as_s
        text(200, "Entreprise créée ou mise à jour et rattachée à l'utilisateur #{auth["email"]?}")
      end

      # --- Outils -----------------------------------------------------------------

      # Le document porte-t-il un formulaire principal, à un millésime où il
      # existe (`FIRST_MILLESIMES`) ?
      private def regime_form?(document : Hash(String, JSON::Any), period : Hash(String, JSON::Any)) : Bool
        millesime = period["millesime"]?.try(&.as_i?) || 9999
        REGIME_FORMS.any? { |name| document.has_key?(name) && millesime >= FIRST_MILLESIMES.fetch(name, 0) }
      end

      # DAS2 : un objet `repetitionDAS2TV` par bénéficiaire, natures dans
      # `repetitionDAS2MontantSommesVersees` (réponses de TELEDEC du
      # 29 septembre 2026) ; `nil` si la forme est bonne.
      private def das2_invalid(block : JSON::Any) : String?
        items = block["repetitionDAS2TV"]?.try(&.as_a?) || return "repetitionDAS2TV absent"
        items.each do |item|
          amounts = item["repetitionDAS2MontantSommesVersees"]?.try(&.as_a?)
          return "repetitionDAS2MontantSommesVersees absent" if amounts.nil? || amounts.empty?
          return "nature ou montant absent" unless amounts.all? { |amount| amount["CA"]? && amount["BA"]? }
          return "CA hors de repetitionDAS2MontantSommesVersees" if item["CA"]?
        end
        nil
      end

      private def store(remote_id : String, form : String, reference : String, body : String, prefix : String,
                        email : String, status : String, callback_url : String?) : Deposit
        if existing = deposits[remote_id]?
          # Une déclaration déjà créée par l'API est mise à jour.
          existing.reference = reference
          existing.body = body
          existing.status = status unless existing.status == "OK"
          existing.report = nil unless existing.status == "OK"
          existing.callback_url = callback_url
          return existing
        end
        @next_id += 1
        deposits[remote_id] = Deposit.new(remote_id, form, reference, body, prefix, email, @next_id, status, callback_url)
      end

      private def lookup(form : String?, siren : String?, date_fin : String?, echeance : String?) : Deposit?
        key = "#{form}:#{siren}:#{date_fin}"
        deposits[echeance ? "#{key}:#{echeance}" : key]? || deposits.values.find { |item| item.remote_id.starts_with?("#{key}:") && echeance.nil? }
      end

      private def report(deposit : Deposit, status : String, forms_status : String,
                         extra : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
        parts = deposit.remote_id.split(':')
        report = {
          "declarationId"     => JSON::Any.new(deposit.declaration_id),
          "reference"         => JSON::Any.new(deposit.reference),
          "siren"             => JSON::Any.new(parts[1]),
          "declarationType"   => JSON::Any.new(declaration_type(deposit.form)),
          "formulaire"        => JSON::Any.new(deposit.form),
          "dateFin"           => JSON::Any.new(parts[2]),
          "status"            => JSON::Any.new(status),
          "declarationStatus" => JSON::Any.new(status),
          "statusLibelle"     => JSON::Any.new(status == "OK" ? "Déclaration acceptée" : "Déclaration rejetée"),
          "formulairesStatus" => JSON::Any.new(forms_status),
          "dateHeureDGFiP"    => JSON::Any.new("2027-05-10T02:00:00"),
          "referenceDGFiP"    => JSON::Any.new("DGFIP-#{deposit.declaration_id}"),
        }
        report.merge(extra)
      end

      # Type de rappel d'un formulaire (réponses de TELEDEC du 29 septembre
      # 2026) : DAS2 `Part`, relevés d'IS `Paiement`.
      private def declaration_type(form : String) : String
        case form
        when "liasse"       then "Liasse"
        when "DAS2"         then "Part"
        when "2571", "2572" then "Paiement"
        else                     "TVA"
        end
      end

      private def text(status : Int32, body : String) : Remote::Response
        Remote::Response.new(status, body, "text/plain; charset=UTF-8")
      end

      private def json(status : Int32, body) : Remote::Response
        Remote::Response.new(status, body.to_json, "application/json")
      end
    end
  end
end
