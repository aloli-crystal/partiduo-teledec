# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Exploration du stage de TELEDEC (optionnelle) : plutôt que de solliciter
# TELEDEC, la suite essaie sur le stage plusieurs variantes argumentées et
# dresse le tableau « variante → acceptée / refusée (message de TELEDEC
# expurgé) ». Sections :
#
# 1. *DAS2 seule*, toujours refusée par le stage (« aucun formulaire de
#    TVA ou de paiement ou de liasse… ») : régime de l'entreprise à sa
#    création, millésime, régime dans la payload, période, déclaration
#    préalable ou jointe, bloc minimal.
# 2. *Greffe* : amorce `POST /service/nouvelle-declaration`, corps de plus
#    en plus complet (D-TDC9-001), sur une SAS de test ; s'arrête à
#    l'adresse rendue, sans jamais finaliser le dépôt.
# 3. *Liasse et `#CREATION-AUTO`* : la création automatique suffit-elle,
#    sans `creation-entreprise` préalable (D-TDC9-004) ?
#
# Deuxième série (D-TDC10-003), après la première exploration :
#
# 4. *DAS2 hors ISRS* : le régime dans la payload (`ISRN`, `BICRS`,
#    `BICRN`, `BNCDC`, entreprise créée au même régime) suffit-il ?
# 5. *BICRS* : cause du « Misformatted JSON » de D6, création seule
#    (forme en clair ou codée, omise, sans régime de TVA ; témoins).
# 6. *Jeton du greffe* : noms possibles du droit `nouvelle-declaration`,
#    réponse du service des jetons (sans le jeton) ; amorces G1 à G5 avec
#    le premier nom accordé.
# 7. *Suivi* : un dépôt accepté (DAS2, liasse) relu après 0, 10, 30 et
#    60 s, puis avec des variantes de paramètres, et la liste des
#    déclarations de l'entreprise : délai ou paramètres faux ?
#
# Troisième série (D-TDC11-003), après la deuxième :
#
# 8. *Jetons de la liste* : droits `stage/liste-declarations` et, à part,
#    `stage/mes-declarations` demandés au service des jetons (réponse
#    affichée sans le jeton), et jeton sans droit nommé (tous ceux du
#    partenaire, d'après la documentation).
# 9. *Liste des déclarations* : si `liste-declarations` est accordé, dépôts
#    d'une DAS2 et d'une liasse puis, aussitôt, `GET /service/declarations`
#    (liens retirés) : le dépôt existe-t-il, sous quels formulaire, dates et
#    statut ? Puis `declaration-status` avec exactement ces valeurs.
# 10. *Lien ouvert* : après le dépôt d'une DAS2, simple `GET` de l'adresse
#    rendue (redirections suivies, sur le stage seulement, rien cliqué ni
#    envoyé), puis suivi et liste : le dépôt n'existerait-il chez TELEDEC
#    qu'une fois le lien ouvert ?
#
# Activée seulement si `~/.config/partiduo/teledec-sandbox.env` porte les
# identifiants du stage *et* si `TELEDEC_EXPLORATION=1` ; exige aussi le
# domaine du partenaire (`TELEDEC_USER_DOMAIN`). Tout part sur le stage,
# rien vers la DGFiP : marque blanche avec `retournerLien` (lien sans
# envoi), liasse sans bouton « Envoyer », greffe amorcé seulement. Chaque
# variante a sa propre entreprise fictive (SIREN à clé valide, distinct,
# préfixe 998, série `TELEDEC_EXPLORATION_SERIE` ou tirée de l'heure : une
# nouvelle exécution repart d'entreprises neuves). Messages expurgés
# (`SandboxSpec.scrub`) ; le tableau est affiché et écrit dans un fichier
# lisible du seul utilisateur (0600), dont le chemin s'affiche :
#
#   TELEDEC_EXPLORATION=1 crystal spec spec/integration/exploration_spec.cr
module Teledec::Exploration
  alias Sandbox = Teledec::SandboxSpec
  alias Formats = Teledec::Remote::Formats

  STAGE = HttpTransport::API_URLS["sandbox"]

  # Résultat d'une variante : `accepted` vrai, faux, ou `nil` (non jouée).
  record Outcome, section : String, variant : String, accepted : Bool?, detail : String

  class_getter outcomes = [] of Outcome
  # Chaque issue est aussi affichée au fil de l'eau.
  class_property? verbose : Bool = true

  def self.enabled? : Bool
    !Sandbox.values.nil? && ENV["TELEDEC_EXPLORATION"]? == "1"
  end

  # Série des SIREN fictifs de cette exécution (trois chiffres).
  class_getter serie : Int32 do
    ENV["TELEDEC_EXPLORATION_SERIE"]?.try(&.to_i?).try(&.%(1000)) || (Time.utc.to_unix // 60 % 1000).to_i
  end

  # SIREN fictif à clé valide (Luhn) : `998`, série, numéro de variante.
  def self.siren(number : Int32) : String
    with_check("998#{serie.to_s.rjust(3, '0')}#{number.to_s.rjust(2, '0')}")
  end

  # SIRET du siège : SIREN, `0001`, clé.
  def self.siret(siren : String) : String
    with_check("#{siren}0001")
  end

  # Ajoute le chiffre de contrôle de Luhn.
  def self.with_check(digits : String) : String
    sum = digits.reverse.chars.each_with_index.sum do |(char, index)|
      value = char.to_i
      if index.even?
        value *= 2
        value -= 9 if value > 9
      end
      value
    end
    "#{digits}#{(10 - sum % 10) % 10}"
  end

  def self.luhn?(digits : String) : Bool
    with_check(digits[0..-2]) == digits
  end

  # Joue une variante et note son issue ; une exception est notée, jamais
  # propagée (l'exploration va au bout).
  def self.attempt(section : String, variant : String, & : -> {Bool?, String}) : Nil
    accepted, detail = yield
    note(section, variant, accepted, detail)
  rescue ex : TransportError
    note(section, variant, false, "#{ex.key} — #{ex.params.values.join(" ; ")}")
  rescue ex
    note(section, variant, nil, "erreur locale : #{ex.class} #{ex.message}")
  end

  private def self.note(section : String, variant : String, accepted : Bool?, detail : String) : Nil
    clean = Sandbox.scrub(detail)
    outcomes << Outcome.new(section, variant, accepted, clean)
    return unless verbose?
    STDOUT.puts "  [#{label(accepted)}] #{section} — #{variant} : #{clean}"
    STDOUT.flush
  end

  def self.label(accepted : Bool?) : String
    case accepted
    when true  then "acceptée"
    when false then "refusée"
    else            "non jouée"
    end
  end

  # Tableau lisible (AsciiDoc), une ligne par variante.
  def self.report : String
    String.build do |io|
      io << "= Exploration du stage de TELEDEC — " << Time.local.to_s("%d/%m/%Y %H:%M") << "\n\n"
      io << "Série de SIREN fictifs : 998" << serie.to_s.rjust(3, '0') << "xx.\n\n"
      io << "[cols=\"1,3,1,5\",options=\"header\"]\n|===\n|Section |Variante |Issue |Réponse de TELEDEC (expurgée)\n"
      outcomes.each do |item|
        io << "|" << item.section << " |" << item.variant.gsub('|', '/') << " |" << label(item.accepted)
        io << " |" << item.detail.gsub('|', '/') << "\n"
      end
      io << "|===\n"
    end
  end

  # Écrit le tableau dans un fichier 0600 (`TELEDEC_EXPLORATION_FILE`, sinon
  # dossier temporaire) ; rend son chemin.
  def self.write_report(path : String = ENV["TELEDEC_EXPLORATION_FILE"]?.presence ||
                          File.join(Dir.tempdir, "partiduo-teledec-exploration-#{Time.local.to_s("%Y%m%d-%H%M%S")}.adoc")) : String
    File.open(path, "w", perm: 0o600) do |file|
      File.chmod(path, 0o600)
      file.print report
    end
    path
  end

  # --- Échanges bruts avec le stage ---------------------------------------------

  # Échange réel qui garde la dernière réponse du service des jetons.
  class TokenCapture < Remote::Exchange
    getter token_body : String = ""
    getter token_request : String = ""

    def call(request : Remote::Request) : Remote::Response
      response = Remote::Net.new.call(request)
      if request.url == HttpTransport::AUTH_URL && response.ok?
        @token_body = response.body
        @token_request = request.body
      end
      response
    end
  end

  # Client brut du stage : jeton donné (`Client.adapter` : celui de
  # l'adaptateur réel, droits facultatifs compris, avec son repli), puis
  # requêtes libres.
  class Client
    getter scopes : Array(String)
    @token : String

    def initialize(@token : String, @scopes : Array(String))
    end

    def self.adapter(credentials : Credentials) : Client
      capture = TokenCapture.new
      Sandbox.transport(capture).check(credentials)
      new(JSON.parse(capture.token_body)["access_token"].as_s,
        URI::Params.parse(capture.token_request)["scope"]?.to_s.split(' ').map(&.lchop("stage/")))
    end

    def post(path : String, body : String, type : String = "application/json") : Remote::Response
      call("POST", path, body, type)
    end

    def get(path : String) : Remote::Response
      call("GET", path, "", nil)
    end

    private def call(method : String, path : String, body : String, type : String?) : Remote::Response
      headers = HTTP::Headers{"Authorization" => "Bearer #{@token}", "Accept" => "application/json, text/plain"}
      type.try { |value| headers["Content-Type"] = value }
      Remote::Net.new.call(Remote::Request.new(method, "#{STAGE}#{path}", headers, body))
    end
  end

  # Message lisible d'une réponse de TELEDEC.
  def self.message(response : Remote::Response) : String
    body = response.body.strip
    parsed = JSON.parse(body)
    if hash = parsed.as_h?
      %w[message erreur error_description error status].each do |name|
        hash[name]?.try(&.as_s?).try { |text| return text }
      end
    end
    body
  rescue JSON::ParseException
    response.body.strip
  end

  # Issue d'un dépôt en marque blanche : 200 sans `message`, acceptée.
  def self.white_label_outcome(response : Remote::Response) : {Bool, String}
    text = message(response)
    hash = (JSON.parse(response.body).as_h? rescue nil)
    accepted = response.ok? && !(hash && hash["message"]?)
    {accepted, accepted ? "HTTP #{response.status} (lien rendu : #{hash.try(&.has_key?("lien")) ? "oui" : "non"})" : "HTTP #{response.status} : #{text}"}
  end

  # État chez TELEDEC après un dépôt accepté (contrôles internes).
  def self.state(client : Client, email : String, siren : String, date_fin : String, form : String) : String
    "suivi " + status_answer(client, {"email" => email, "siren" => siren, "date_fin" => date_fin, "formulaire" => form})[1]
  end

  # Route de suivi avec des paramètres libres : trouvée (HTTP 200) ou non,
  # et la réponse lisible.
  def self.status_answer(client : Client, params : Hash(String, String)) : {Bool, String}
    query = URI::Params.build { |form| params.each { |name, value| form.add name, value } }
    response = client.get("/service/declaration-status?#{query}")
    {response.ok?, "HTTP #{response.status} : #{message(response)}"}
  end

  # Clés retirées d'une déclaration listée par TELEDEC : liens temporaires
  # et documents (ils portent des jetons).
  HIDDEN_KEYS = /lien|url|pdf|token|edi|accuse|hash/i

  # Déclarations que TELEDEC connaît pour l'entreprise
  # (`GET /service/declarations`), sans liens : dates et formulaires sous
  # lesquels un dépôt est rangé.
  def self.declarations(client : Client, email : String, siren : String) : {Bool, String}
    query = URI::Params.build do |form|
      form.add "siren", siren
      form.add "email", email
    end
    response = client.get("/service/declarations?#{query}")
    return {false, "HTTP #{response.status} : #{message(response)}"} unless response.ok?
    parsed = JSON.parse(response.body)
    items = parsed.as_a? || parsed.as_h?.try { |hash| hash.values.find(&.as_a?).try(&.as_a) } || [parsed]
    shown = items.map do |item|
      item.as_h?.try(&.reject { |key, _| key.matches?(HIDDEN_KEYS) }.to_json) || item.to_json
    end
    {true, "HTTP 200, #{items.size} déclaration(s) : #{shown.join(" ; ")}"}
  rescue JSON::ParseException
    {false, "réponse illisible : #{response.try(&.body).to_s[0, 200]}"}
  end

  # Demande brute d'un jeton au service des jetons, avec les droits
  # `scopes` (préfixe compris ; liste vide : aucun paramètre `scope`, tous
  # les droits du partenaire selon la documentation) : rend l'issue, la
  # réponse sans le jeton (statut, erreur, droits annoncés), le jeton s'il
  # est accordé et les droits annoncés (sans préfixe).
  def self.token_probe(credentials : Credentials, scopes : Array(String)) : {Bool, String, String?, Array(String)}
    basic = Base64.strict_encode("#{credentials.login}:#{credentials.api_key}")
    headers = HTTP::Headers{"Authorization" => "Basic #{basic}", "Content-Type" => "application/x-www-form-urlencoded",
                            "Accept" => "application/json"}
    body = URI::Params.build do |form|
      form.add "grant_type", "client_credentials"
      form.add "scope", scopes.join(' ') unless scopes.empty?
    end
    response = Remote::Net.new.call(Remote::Request.new("POST", HttpTransport::AUTH_URL, headers, body))
    answer = (JSON.parse(response.body).as_h? rescue nil) || {} of String => JSON::Any
    token = answer["access_token"]?.try(&.as_s?)
    announced = answer["scope"]?.try(&.as_s?)
    if response.ok? && token
      names = announced.try(&.split(' ').reject(&.empty?).map(&.lchop("stage/"))) || [] of String
      {true, "HTTP #{response.status}, droits annoncés : #{announced || "(aucun champ scope)"}", token, names}
    else
      reason = %w[error error_description message].compact_map { |name| answer[name]?.try(&.as_s?) }.join(" — ")
      {false, "HTTP #{response.status} : #{reason.presence || response.body.strip[0, 200]}", nil, [] of String}
    end
  end

  # Droits de l'adaptateur réel, sans les facultatifs, préfixe du stage.
  def self.adapter_scopes : Array(String)
    (HttpTransport::SCOPES - HttpTransport::OPTIONAL_SCOPES).map { |scope| "stage/#{scope}" }
  end

  # Droit de la liste des déclarations (`GET /service/declarations`).
  LIST_SCOPE = "liste-declarations"

  # Client portant les droits de l'adaptateur et `liste-declarations` :
  # demandés ensemble, sinon jeton sans droit nommé s'il annonce ce droit ;
  # `nil` si le service des jetons ne l'accorde pas.
  def self.list_client(credentials : Credentials) : Client?
    scopes = adapter_scopes + ["stage/#{LIST_SCOPE}"]
    accepted, _, token, _ = token_probe(credentials, scopes)
    return Client.new(token, scopes.map(&.lchop("stage/"))) if accepted && token
    accepted, _, token, announced = token_probe(credentials, [] of String)
    Client.new(token, announced) if accepted && token && announced.includes?(LIST_SCOPE)
  end

  # Déclarations listées par TELEDEC (`GET /service/declarations`), objets
  # bruts ; `nil` et la réponse lisible si la route refuse.
  def self.listed(client : Client, email : String, siren : String) : {Array(Hash(String, JSON::Any))?, String}
    query = URI::Params.build do |form|
      form.add "siren", siren
      form.add "email", email
    end
    response = client.get("/service/declarations?#{query}")
    return {nil, "HTTP #{response.status} : #{message(response)}"} unless response.ok?
    parsed = JSON.parse(response.body)
    items = parsed.as_a? || parsed.as_h?.try { |hash| hash.values.find(&.as_a?).try(&.as_a) } || [parsed]
    {items.compact_map(&.as_h?), "HTTP 200"}
  rescue JSON::ParseException
    {nil, "réponse illisible"}
  end

  # Suivi interrogé avec exactement les valeurs d'une déclaration listée :
  # formulaire (champ `formulaire` s'il existe, sinon `declarationType`,
  # puis le code de l'adaptateur), `dateFin`, et `date_echeance` si la
  # liste en donne une.
  def self.status_from_listed(client : Client, email : String, siren : String, item : Hash(String, JSON::Any),
                              fallback : String) : Array({String, Bool, String})
    date_fin = item["dateFin"]?.try(&.as_s?) || "2025-12-31"
    echeance = %w[dateEcheance date_echeance echeance].compact_map { |name| item[name]?.try(&.as_s?) }.first?
    forms = [item["formulaire"]?.try(&.as_s?), item["declarationType"]?.try(&.as_s?), fallback].compact.uniq!
    forms.map do |form|
      params = {"email" => email, "siren" => siren, "date_fin" => date_fin, "formulaire" => form}
      echeance.try { |day| params["date_echeance"] = day }
      found, detail = status_answer(client, params)
      {"formulaire #{form}, date_fin #{date_fin}#{echeance ? ", date_echeance #{echeance}" : ""}", found, detail}
    end
  end

  # Ouvre l'adresse rendue par la marque blanche comme un navigateur : `GET`
  # seuls, redirections suivies (cinq au plus) avec leurs cookies, sur le
  # stage seulement ; rien n'est cliqué ni envoyé. Rend l'issue et les
  # étapes (adresses tronquées, titre de la page).
  def self.open_link(url : String) : {Bool, String}
    steps = [] of String
    cookies = HTTP::Cookies.new
    current = URI.parse(url)
    6.times do
      unless current.scheme == "https" && current.host == URI.parse(STAGE).host
        return {false, "#{steps.join(" → ")} ; adresse hors du stage, non ouverte : #{Sandbox.truncated(current.to_s)}"}
      end
      headers = HTTP::Headers{"Accept" => "text/html,application/xhtml+xml"}
      cookies.add_request_headers(headers)
      client = HTTP::Client.new(current)
      client.connect_timeout = 10.seconds
      client.read_timeout = 60.seconds
      response = begin
        client.get(current.request_target, headers: headers)
      ensure
        client.close
      end
      cookies.fill_from_server_headers(response.headers)
      steps << "HTTP #{response.status_code} #{Sandbox.truncated(current.to_s)}"
      if response.status.redirection? && (location = response.headers["Location"]?)
        current = current.resolve(location)
        next
      end
      title = response.body.match(/<title[^>]*>(.*?)<\/title>/im).try(&.[1].strip)
      return {response.success?, "#{steps.join(" → ")} ; #{response.content_type || "type inconnu"}, " \
                                 "#{response.body.bytesize} octets, titre « #{title || "aucun"} »"}
    end
    {false, "#{steps.join(" → ")} ; plus de cinq redirections"}
  end

  # --- Entreprises de test ------------------------------------------------------

  def self.identity(siren : String, legal_form : String = "SAS") : Payload::Identity
    Payload::Identity.new("PARTIDUO EXPLORATION #{siren[-3..]}", legal_form, siren, "", "", "1000.00", "3 rue des Lilas",
      "69003", "Lyon", "FR", Sandbox::EMAIL)
  end

  # Crée l'entreprise et son compte (`creation-entreprise`), régime
  # `regime`, forme `legal_form` (envoyée telle quelle : code de TELEDEC
  # attendu, `SRL` pour une SARL), régime de TVA `vat` (`nil` : champ
  # omis).
  def self.create_company(siren : String, regime : String?, legal_form : String? = "SAS", vat : String? = "Normal") : String
    account = Sandbox.transport.account_email(siren)
    company = {"siren" => siren, "name" => "PARTIDUO EXPLORATION #{siren[-3..]}", "yearEndMonth" => 12, "yearEndDay" => 31,
               "addressStreet" => "3 rue des Lilas", "addressPostalCode" => "69003", "addressCity" => "Lyon",
               "addressCountry" => "FR"} of String => String | Int32
    legal_form.try { |value| company["legalForm"] = value }
    vat.try { |value| company["regimeFiscalTVA"] = value }
    regime.try { |value| company["fullRegimeFiscal"] = value }
    Sandbox.transport.create_company(Sandbox.credentials(siret: siret(siren)), company, Sandbox.password_hash, account)
    account
  end

  # Création de l'entreprise, son refus nommé comme tel (pour distinguer
  # la route qui refuse) : l'adresse du compte, ou `nil` et le refus.
  def self.created(siren : String, regime : String?, legal_form : String? = "SAS",
                   vat : String? = "Normal") : {String?, String}
    {create_company(siren, regime, legal_form, vat), "création de l'entreprise acceptée"}
  rescue ex : TransportError
    {nil, "création de l'entreprise refusée (creation-entreprise) : #{ex.key} — #{ex.params.values.join(" ; ")}"}
  end

  def self.submission(payload : Payload, due_on : String? = nil) : Submission
    Submission.new("partiduo-exploration-#{payload.identity.siren}-#{Time.utc.to_unix}", payload.kind, payload.forms,
      payload.to_json, payload.fingerprint, due_on: due_on, year_end: "2025-12-31")
  end

  def self.offline_credentials(siren : String) : Credentials
    Credentials.new("x", "y", "sandbox", Sandbox::EMAIL, siret(siren))
  end

  # Document DAS2 de 2025 de l'adaptateur pour l'entreprise `siren`, à
  # l'IS réel simplifié : régime `ISRS` dans l'identité (D-TDC10-002) ;
  # `with_regime` le change ou le retire.
  def self.das2_document(siren : String, account : String, legal_form : String = "SAS") : Hash(String, JSON::Any)
    lines = Sandbox.das2_payload.das2 || [] of Payload::Das2Line
    payload = Payload.new("das2", ["DAS2"], identity(siren, legal_form), "2025-01-01", "2025-12-31", 0, nil, nil, nil,
      lines, {"threshold" => "1200", "tax_system" => "is_rsi"})
    due = Calendar.das2(2025).to_s("%F")
    JSON.parse(Formats.white_label(payload, submission(payload, due), offline_credentials(siren), Time.utc, account)).as_h
  end

  # Document CA3 « néant » de décembre 2025 pour l'entreprise `siren`.
  def self.ca3_document(siren : String, account : String) : Hash(String, JSON::Any)
    payload = Payload.new("vat_ca3", ["3310-CA3"], identity(siren), "2025-12-01", "2025-12-31", 12, nil, nil,
      {"3310-CA3" => {} of String => String}, nil, {"periodicity" => "month"})
    JSON.parse(Formats.white_label(payload, submission(payload, "2026-01-19"), offline_credentials(siren), Time.utc,
      account)).as_h
  end

  # Régime de l'identité remplacé (`nil` : retiré, comme avant
  # D-TDC10-002).
  def self.with_regime(document : Hash(String, JSON::Any), regime : String?) : Hash(String, JSON::Any)
    edit(document, "identity") do |part|
      regime ? (part["fullRegimeFiscal"] = JSON::Any.new(regime)) : part.delete("fullRegimeFiscal")
    end
  end

  # Dépôt d'une DAS2 en marque blanche, puis, s'il est accepté, son suivi.
  def self.deposit_das2(client : Client, siren : String, document : Hash(String, JSON::Any), account : String) : {Bool?, String}
    response = client.post(WHITE_LABEL, document.to_json)
    accepted, detail = white_label_outcome(response)
    detail += " ; " + state(client, account, siren, "2025-12-31", "DAS2") if accepted
    {accepted.as(Bool?), detail}
  end

  def self.edit(document : Hash(String, JSON::Any), block : String, & : Hash(String, JSON::Any) -> _) : Hash(String, JSON::Any)
    part = document[block].as_h.dup
    yield part
    document.merge({block => JSON::Any.new(part)})
  end

  # Amorces du greffe G1 à G5, corps de plus en plus complet, sur la SAS
  # `siren` ; jamais finalisées. `tag` distingue le jeton employé.
  def self.play_greffe(client : Client, siren : String, account : String, tag : String) : Nil
    payload = Payload.new("greffe", ["greffe"], identity(siren), "2025-01-01", "2025-12-31", 0, nil, nil, nil, nil,
      {"confidential" => "0"})
    full = JSON.parse(Formats.greffe(payload, submission(payload), offline_credentials(siren), Time.utc, account)).as_h
    auth = full["auth"].as_h
    short = JSON::Any.new(auth.select("email", "timestamp"))
    bodies = [
      {"G1 minimal : formulaire seul", {"formulaire" => full["formulaire"]}},
      {"G2 + auth.email et timestamp", {"formulaire" => full["formulaire"], "auth" => short}},
      {"G3 + identity", {"formulaire" => full["formulaire"], "auth" => short, "identity" => full["identity"]}},
      {"G4 + period", {"formulaire" => full["formulaire"], "auth" => short, "identity" => full["identity"],
                       "period" => full["period"]}},
      {"G5 + auth.url et retournerLien (corps de l'adaptateur)",
       full.merge({"auth" => JSON::Any.new(auth.merge({"url" => JSON::Any.new("https://exemple.invalid/hooks/TELEDEC/callback")}))})},
    ]
    bodies.each do |(variant, body)|
      attempt("Greffe", "#{variant}#{tag}") do
        unless client.scopes.includes?("nouvelle-declaration")
          next {nil.as(Bool?), "droit nouvelle-declaration absent du jeton (refusé par le service des jetons)"}
        end
        response = client.post("/service/nouvelle-declaration", body.to_json)
        url = Formats.redirect_url(response.body)
        if response.ok? && !url.empty?
          {true.as(Bool?), "HTTP #{response.status}, adresse rendue : #{Sandbox.truncated(url)}"}
        else
          {false.as(Bool?), "HTTP #{response.status} : #{message(response)}"}
        end
      end
    end
  end

  WHITE_LABEL = "/service/declaration-marque-blanche"
end

private alias Explore = Teledec::Exploration
private alias Sandbox = Teledec::SandboxSpec

describe "Exploration du stage de TELEDEC (optionnelle)" do
  it "forme des SIREN et des SIRET fictifs à clé valide, distincts" do
    numbers = (1..14).to_a + [20, 21, 30, 31] + (40..47).to_a + [50, 51] + (60..62).to_a
    sirens = numbers.map { |number| Explore.siren(number) }
    sirens.uniq.size.should eq(numbers.size)
    sirens.all? { |siren| siren.size == 9 && siren.starts_with?("998") && Explore.luhn?(siren) }.should be_true
    sirens.all? { |siren| Explore.luhn?(Explore.siret(siren)) && Explore.siret(siren).size == 14 }.should be_true
    Explore.luhn?(Sandbox::SIREN).should be_true # entreprise de la suite du stage
  end

  it "dépose la DAS2 avec le régime ISRS de l'adaptateur, retiré ou remplacé à la demande, sans autre formulaire" do
    siren = Explore.siren(11)
    document = Explore.das2_document(siren, "compte@exemple.org")
    (document.keys - %w[auth identity period]).should eq(["DAS2"])
    document["identity"]["fullRegimeFiscal"].as_s.should eq("ISRS")
    Explore.with_regime(document, nil)["identity"]["fullRegimeFiscal"]?.should be_nil
    Explore.with_regime(document, "ISRN")["identity"]["fullRegimeFiscal"].as_s.should eq("ISRN")
    document["identity"]["fullRegimeFiscal"].as_s.should eq("ISRS") # document d'origine intact
  end

  it "n'ouvre jamais un lien hors du stage (production comprise), sans appel réseau" do
    %w[https://www.teledec.fr/service/declaration/1 http://stage.teledec.fr/service/declaration/1
      https://exemple.invalid/x].each do |url|
      opened, detail = Explore.open_link(url)
      opened.should be_false
      detail.should contain("adresse hors du stage, non ouverte")
    end
  end

  it "écrit un tableau expurgé dans un fichier à droits 0600" do
    saved = Explore.outcomes.dup
    Explore.verbose = false
    path = File.join(Dir.tempdir, "partiduo-teledec-exploration-essai-#{Random::Secure.hex(4)}.adoc")
    begin
      Explore.attempt("DAS2", "essai hors ligne") { {false.as(Bool?), "refus | eyJhbGciOiJIUzI1NiJ9.eyJ4IjoxfQ"} }
      Explore.write_report(path)
      (File.info(path).permissions.value & 0o777).should eq(0o600)
      text = File.read(path)
      text.should contain("|DAS2 |essai hors ligne |refusée |refus / ***")
      text.includes?("eyJ").should be_false
    ensure
      File.delete?(path)
      Explore.outcomes.clear
      Explore.outcomes.concat(saved)
      Explore.verbose = true
    end
  end

  if Explore.enabled?
    it "1. DAS2 seule : variantes de la plus probable à la moins probable" do
      Sandbox.require_stage!
      Sandbox.account!
      client = Explore::Client.adapter(Sandbox.credentials)
      section = "DAS2"
      # Première série : DAS2 sans régime dans la payload (comme avant
      # D-TDC10-002), sauf D1 (adaptateur actuel) et D4.
      dated = ->(siren : String, document : Hash(String, JSON::Any), account : String) do
        Explore.deposit_das2(client, siren, Explore.with_regime(document, nil), account)
      end

      Explore.attempt(section, "D1 adaptateur actuel : entreprise ISRS, DAS2 seule, millésime 2026, régime ISRS dans l'identité") do
        siren = Explore.siren(1)
        account = Explore.create_company(siren, "ISRS")
        Explore.deposit_das2(client, siren, Explore.das2_document(siren, account), account)
      end
      Explore.attempt(section, "D2 sans period.millesime (déduit des dates, comme la TVA)") do
        siren = Explore.siren(2)
        account = Explore.create_company(siren, "ISRS")
        document = Explore.edit(Explore.das2_document(siren, account), "period", &.delete("millesime"))
        dated.call(siren, document, account)
      end
      Explore.attempt(section, "D3 entreprise créée sans fullRegimeFiscal (défaut TELEDEC)") do
        siren = Explore.siren(3)
        account = Explore.create_company(siren, nil)
        dated.call(siren, Explore.das2_document(siren, account), account)
      end
      Explore.attempt(section, "D4 identity.fullRegimeFiscal ISRS dans la payload (schéma DAS2-2026)") do
        siren = Explore.siren(4)
        account = Explore.create_company(siren, "ISRS")
        Explore.deposit_das2(client, siren, Explore.with_regime(Explore.das2_document(siren, account), "ISRS"), account)
      end
      Explore.attempt(section, "D5 entreprise ISRN (régime réel normal)") do
        siren = Explore.siren(5)
        account = Explore.create_company(siren, "ISRN")
        dated.call(siren, Explore.das2_document(siren, account), account)
      end
      Explore.attempt(section, "D6 entreprise BICRS (IR), forme « SARL » en clair") do
        siren = Explore.siren(6)
        account = Explore.create_company(siren, "BICRS", "SARL")
        dated.call(siren, Explore.das2_document(siren, account), account)
      end
      Explore.attempt(section, "D7 période réduite à begin, end, reference (guide de la marque blanche)") do
        siren = Explore.siren(7)
        account = Explore.create_company(siren, "ISRS")
        document = Explore.edit(Explore.das2_document(siren, account), "period") do |part|
          part.select!("begin", "end", "reference")
        end
        dated.call(siren, document, account)
      end
      Explore.attempt(section, "D8 après une CA3 néant de décembre 2025 déposée sur l'entreprise") do
        siren = Explore.siren(8)
        account = Explore.create_company(siren, "ISRS")
        first = client.post(Explore::WHITE_LABEL, Explore.ca3_document(siren, account).to_json)
        ca3, ca3_detail = Explore.white_label_outcome(first)
        next {nil.as(Bool?), "CA3 préalable refusée : #{ca3_detail}"} unless ca3
        dated.call(siren, Explore.das2_document(siren, account), account)
      end
      Explore.attempt(section, "D9 DAS2 jointe à une CA3 néant dans la même payload") do
        siren = Explore.siren(9)
        account = Explore.create_company(siren, "ISRS")
        document = Explore.das2_document(siren, account)
        document["3310CA3"] = Explore.ca3_document(siren, account)["3310CA3"]
        dated.call(siren, document, account)
      end
      Explore.attempt(section, "D10 bloc DAS2 minimal : un bénéficiaire personne morale, une nature") do
        siren = Explore.siren(10)
        account = Explore.create_company(siren, "ISRS")
        document = Explore.edit(Explore.das2_document(siren, account), "DAS2") do |part|
          first = part["repetitionDAS2TV"].as_a.first.as_h.select("AF_3036_1", "AF_3039_1", "repetitionDAS2MontantSommesVersees")
          amounts = first["repetitionDAS2MontantSommesVersees"].as_a.first(1)
          first["repetitionDAS2MontantSommesVersees"] = JSON::Any.new(amounts)
          part.select!("AA_3036_1", "AA_3039_1")
          part["repetitionDAS2TV"] = JSON::Any.new([JSON::Any.new(first)])
        end
        dated.call(siren, document, account)
      end
    end

    it "2. Greffe : amorce nouvelle-declaration, corps de plus en plus complet (jamais finalisé)" do
      Sandbox.require_stage!
      Sandbox.account!
      siren = Explore.siren(20)
      account = Explore.create_company(siren, "ISRS", "SAS")
      client = Explore::Client.adapter(Sandbox.credentials(siret: Explore.siret(siren)))
      Explore.play_greffe(client, siren, account, "")
    end

    it "3. Liasse : #CREATION-AUTO OUI suffit-il sans creation-entreprise ?" do
      Sandbox.require_stage!
      Sandbox.account!
      section = "Liasse"
      source = Sandbox.instance_setting("TELEDEC_SOURCE") || "API"
      [{30, false, "L1 #CREATION-AUTO OUI, sans creation-entreprise"},
       {31, true, "L2 témoin : creation-entreprise puis liasse"}].each do |(number, create, variant)|
        Explore.attempt(section, variant) do
          siren = Explore.siren(number)
          account = create ? Explore.create_company(siren, "ISRS") : Sandbox.transport.account_email(siren)
          client = Explore::Client.adapter(Sandbox.credentials(siret: Explore.siret(siren)))
          base = Sandbox.liasse_payload
          payload = Teledec::Payload.new("liasse", base.forms, Explore.identity(siren), base.period_from, base.period_to,
            0, base.balance)
          credentials = Sandbox.credentials(siret: Explore.siret(siren))
          body = Teledec::Remote::Formats.liasse(payload, Explore.submission(payload), credentials, source, false, account)
          response = client.post("/service/liasse", body, "text/plain; charset=utf-8")
          url = Teledec::Remote::Formats.redirect_url(response.body)
          if !response.ok? || url.empty?
            next {false.as(Bool?), "HTTP #{response.status} : #{Explore.message(response)}"}
          end
          {true.as(Bool?), "liasse acceptée ; " + Explore.state(client, account, siren, "2025-12-31", "liasse")}
        end
      end
    end

    # --- Deuxième série (D-TDC10-003) --------------------------------------------

    it "4. DAS2 : le régime dans la payload suffit-il hors IS réel simplifié ?" do
      Sandbox.require_stage!
      Sandbox.account!
      client = Explore::Client.adapter(Sandbox.credentials)
      # Régime, forme juridique (code de TELEDEC à la création, texte de
      # Partiduo dans l'identité de la DAS2), numéro de variante.
      [{"ISRN", "SAS", "SAS", 11}, {"BICRS", "SRL", "SARL", 12}, {"BICRN", "SRL", "SARL", 13},
       {"BNCDC", "EI", "EI", 14}].each do |(regime, code, form, number)|
        Explore.attempt("DAS2", "D#{number} entreprise #{regime} (#{code}), identity.fullRegimeFiscal #{regime}") do
          siren = Explore.siren(number)
          account, created = Explore.created(siren, regime, code)
          next {nil.as(Bool?), created} unless account
          Explore.deposit_das2(client, siren, Explore.with_regime(Explore.das2_document(siren, account, form), regime), account)
        end
      end
    end

    it "5. BICRS : cause du « Misformatted JSON » (création de l'entreprise seule)" do
      Sandbox.require_stage!
      Sandbox.account!
      # Régime, forme juridique (`nil` : omise), régime de TVA (`nil` :
      # omis) ; aucun dépôt, la création seule.
      [{"B1 BICRS, forme « SARL » en clair (comme D6)", "BICRS", "SARL", "Normal"},
       {"B2 BICRS, forme SRL (code de TELEDEC de la SARL)", "BICRS", "SRL", "Normal"},
       {"B3 BICRS, forme SAS", "BICRS", "SAS", "Normal"},
       {"B4 BICRS, forme EI", "BICRS", "EI", "Normal"},
       {"B5 BICRS, sans legalForm", "BICRS", nil, "Normal"},
       {"B6 BICRS, forme SRL, sans regimeFiscalTVA", "BICRS", "SRL", nil},
       {"B7 témoin ISRS, forme « SARL » en clair", "ISRS", "SARL", "Normal"},
       {"B8 BICRN, forme SRL", "BICRN", "SRL", "Normal"}].each_with_index do |(variant, regime, form, vat), index|
        Explore.attempt("BICRS", variant) do
          account, detail = Explore.created(Explore.siren(40 + index), regime, form, vat)
          {!account.nil?.as(Bool?), detail}
        end
      end
    end

    it "6. Greffe : nom du droit demandé au service des jetons, puis amorces avec le premier accordé" do
      Sandbox.require_stage!
      Sandbox.account!
      credentials = Sandbox.credentials
      base = Explore.adapter_scopes
      granted = nil
      [{"J1 stage/nouvelle-declaration (avec les droits de l'adaptateur)", base + ["stage/nouvelle-declaration"]},
       {"J2 stage/nouvelle-declaration seul", ["stage/nouvelle-declaration"]},
       {"J3 nouvelle-declaration sans préfixe", base + ["nouvelle-declaration"]},
       {"J4 stage/nouvelle_declaration", base + ["stage/nouvelle_declaration"]},
       {"J5 stage/nouvelleDeclaration", base + ["stage/nouvelleDeclaration"]}].each do |(variant, scopes)|
        Explore.attempt("Jeton", variant) do
          accepted, detail, token, _ = Explore.token_probe(credentials, scopes)
          granted ||= token.try { |value| {value, scopes.last, variant[0, 2]} }
          {accepted.as(Bool?), detail}
        end
      end
      found = granted
      unless found
        Explore.attempt("Greffe", "G1–G5 (deuxième série)") { {nil.as(Bool?), "aucun nom de droit accordé par le service des jetons"} }
        next
      end
      token, scope, label = found
      siren = Explore.siren(21)
      account, created = Explore.created(siren, "ISRS", "SAS")
      unless account
        Explore.attempt("Greffe", "G1–G5 (jeton #{label})") { {nil.as(Bool?), created} }
        next
      end
      # Le droit accordé est tenu pour celui du greffe : l'amorce le dira.
      Explore.play_greffe(Explore::Client.new(token, ["nouvelle-declaration"]), siren, account, " (jeton #{label}, #{scope})")
    end

    it "7. Suivi : délai après le dépôt ou paramètres de la route ?" do
      Sandbox.require_stage!
      Sandbox.account!
      section = "Suivi"
      # Dépôts acceptés : DAS2 ISRS (adaptateur actuel) et liasse
      # (entreprise créée avant, comme L2).
      das2_siren, liasse_siren = Explore.siren(50), Explore.siren(51)
      das2_account = Explore.create_company(das2_siren, "ISRS")
      liasse_account = Explore.create_company(liasse_siren, "ISRS")
      client = Explore::Client.adapter(Sandbox.credentials(siret: Explore.siret(liasse_siren)))
      deposited = {} of String => Bool
      Explore.attempt(section, "S0 dépôt de la DAS2 (ISRS, régime dans l'identité)") do
        response = client.post(Explore::WHITE_LABEL, Explore.das2_document(das2_siren, das2_account).to_json)
        accepted, detail = Explore.white_label_outcome(response)
        deposited["das2"] = accepted
        {accepted.as(Bool?), detail}
      end
      Explore.attempt(section, "S0 dépôt de la liasse (creation-entreprise avant)") do
        base = Sandbox.liasse_payload
        payload = Teledec::Payload.new("liasse", base.forms, Explore.identity(liasse_siren), base.period_from,
          base.period_to, 0, base.balance)
        credentials = Sandbox.credentials(siret: Explore.siret(liasse_siren))
        source = Sandbox.instance_setting("TELEDEC_SOURCE") || "API"
        body = Teledec::Remote::Formats.liasse(payload, Explore.submission(payload), credentials, source, false, liasse_account)
        response = client.post("/service/liasse", body, "text/plain; charset=utf-8")
        accepted = response.ok? && !Teledec::Remote::Formats.redirect_url(response.body).empty?
        deposited["liasse"] = accepted
        {accepted.as(Bool?), accepted ? "liasse acceptée" : "HTTP #{response.status} : #{Explore.message(response)}"}
      end
      started = Time.instant
      due = Teledec::Calendar.das2(2025).to_s("%F")
      das2_params = {"email" => das2_account, "siren" => das2_siren, "date_fin" => "2025-12-31", "formulaire" => "DAS2"}
      liasse_params = {"email" => liasse_account, "siren" => liasse_siren, "date_fin" => "2025-12-31", "formulaire" => "liasse"}
      probe = ->(variant : String, kind : String, params : Hash(String, String)) do
        Explore.attempt(section, variant) do
          next {nil.as(Bool?), "dépôt #{kind} refusé : rien à suivre"} unless deposited[kind]?
          found, detail = Explore.status_answer(client, params)
          {found.as(Bool?), "#{found ? "trouvé" : "non trouvé"} — #{detail}"}
        end
      end
      # Délai : mêmes paramètres (ceux de l'adaptateur) après 0, 10, 30 et
      # 60 secondes.
      [0, 10, 30, 60].each_with_index do |delay, index|
        wait = delay.seconds - (Time.instant - started)
        sleep wait if wait > Time::Span.zero
        probe.call("S#{index + 1} DAS2, paramètres de l'adaptateur, #{delay} s après", "das2", das2_params)
        probe.call("S#{index + 1} liasse, paramètres de l'adaptateur, #{delay} s après", "liasse", liasse_params)
      end
      # Paramètres (au-delà de 60 s).
      partner = Sandbox::EMAIL
      [{"S5 DAS2 + date_echeance (échéance de la DAS2)", das2_params.merge({"date_echeance" => due})},
       {"S6 DAS2, formulaire Part (declarationType des rappels)", das2_params.merge({"formulaire" => "Part"})},
       {"S7 DAS2, formulaire das2 (minuscules)", das2_params.merge({"formulaire" => "das2"})},
       {"S8 DAS2, date_fin = échéance", das2_params.merge({"date_fin" => due})},
       {"S9 DAS2, date_fin au format 31/12/2025", das2_params.merge({"date_fin" => "31/12/2025"})},
       {"S10 DAS2, siret au lieu du siren", das2_params.merge({"siren" => Explore.siret(das2_siren)})},
       {"S11 DAS2, email du partenaire au lieu du compte", das2_params.merge({"email" => partner})},
       {"S12 DAS2, sans email", das2_params.reject("email")}].each do |(variant, params)|
        probe.call(variant, "das2", params)
      end
      [{"S13 liasse, formulaire 2065", liasse_params.merge({"formulaire" => "2065"})},
       {"S14 liasse, formulaire 2033", liasse_params.merge({"formulaire" => "2033"})},
       {"S15 liasse, date_fin au format 31/12/2025", liasse_params.merge({"date_fin" => "31/12/2025"})},
       {"S16 liasse, email du partenaire au lieu du compte", liasse_params.merge({"email" => partner})},
       {"S17 liasse, sans email", liasse_params.reject("email")}].each do |(variant, params)|
        probe.call(variant, "liasse", params)
      end
      # Ce que TELEDEC range pour chaque entreprise : dates et formulaire
      # sous lesquels chercher le dépôt.
      {"das2" => {das2_account, das2_siren}, "liasse" => {liasse_account, liasse_siren}}.each do |kind, (account, siren)|
        Explore.attempt(section, "S18 déclarations listées (#{kind})") do
          found, detail = Explore.declarations(client, account, siren)
          {found.as(Bool?), detail}
        end
      end
    end

    # --- Troisième série (D-TDC11-003) --------------------------------------------

    it "8. Jetons : droits liste-declarations et mes-declarations, et jeton sans droit nommé" do
      Sandbox.require_stage!
      credentials = Sandbox.credentials
      base = Explore.adapter_scopes
      [{"T0 sans paramètre scope (tous les droits du partenaire)", [] of String},
       {"T1 stage/liste-declarations (avec les droits de l'adaptateur)", base + ["stage/liste-declarations"]},
       {"T2 stage/liste-declarations seul", ["stage/liste-declarations"]},
       {"T3 stage/mes-declarations (avec les droits de l'adaptateur)", base + ["stage/mes-declarations"]},
       {"T4 stage/mes-declarations seul", ["stage/mes-declarations"]}].each do |(variant, scopes)|
        Explore.attempt("Jeton", variant) do
          accepted, detail, _, _ = Explore.token_probe(credentials, scopes)
          {accepted.as(Bool?), detail}
        end
      end
    end

    it "9. Liste : la DAS2 et la liasse déposées existent-elles, sous quels formulaire, dates et statut ?" do
      Sandbox.require_stage!
      Sandbox.account!
      section = "Liste"
      das2_siren, liasse_siren = Explore.siren(60), Explore.siren(61)
      client = Explore.list_client(Sandbox.credentials(siret: Explore.siret(liasse_siren)))
      unless client
        Explore.attempt(section, "L1–L6") { {nil.as(Bool?), "droit liste-declarations refusé par le service des jetons"} }
        next
      end
      das2_account = Explore.create_company(das2_siren, "ISRS")
      liasse_account = Explore.create_company(liasse_siren, "ISRS")
      deposited = {} of String => Bool
      Explore.attempt(section, "L0 dépôt de la DAS2 (ISRS, régime dans l'identité)") do
        response = client.post(Explore::WHITE_LABEL, Explore.das2_document(das2_siren, das2_account).to_json)
        accepted, detail = Explore.white_label_outcome(response)
        deposited["das2"] = accepted
        {accepted.as(Bool?), detail}
      end
      Explore.attempt(section, "L0 dépôt de la liasse (creation-entreprise avant)") do
        base = Sandbox.liasse_payload
        payload = Teledec::Payload.new("liasse", base.forms, Explore.identity(liasse_siren), base.period_from,
          base.period_to, 0, base.balance)
        credentials = Sandbox.credentials(siret: Explore.siret(liasse_siren))
        source = Sandbox.instance_setting("TELEDEC_SOURCE") || "API"
        body = Teledec::Remote::Formats.liasse(payload, Explore.submission(payload), credentials, source, false, liasse_account)
        response = client.post("/service/liasse", body, "text/plain; charset=utf-8")
        accepted = response.ok? && !Teledec::Remote::Formats.redirect_url(response.body).empty?
        deposited["liasse"] = accepted
        {accepted.as(Bool?), accepted ? "liasse acceptée" : "HTTP #{response.status} : #{Explore.message(response)}"}
      end
      {"das2" => {das2_account, das2_siren, "DAS2"}, "liasse" => {liasse_account, liasse_siren, "liasse"}}.each do |kind, (account, siren, form)|
        Explore.attempt(section, "L1 déclarations listées aussitôt (#{kind})") do
          next {nil.as(Bool?), "dépôt #{kind} refusé : rien à lister"} unless deposited[kind]?
          found, detail = Explore.declarations(client, account, siren)
          {found.as(Bool?), detail}
        end
        Explore.attempt(section, "L2 suivi avec les valeurs listées (#{kind})") do
          next {nil.as(Bool?), "dépôt #{kind} refusé : rien à suivre"} unless deposited[kind]?
          items, detail = Explore.listed(client, account, siren)
          next {false.as(Bool?), "liste refusée : #{detail}"} unless items
          next {false.as(Bool?), "liste vide : aucune valeur à reprendre"} if items.empty?
          probes = items.first(3).flat_map { |item| Explore.status_from_listed(client, account, siren, item, form) }
          {probes.any?(&.[1]).as(Bool?), probes.map { |(what, found, answer)| "#{what} : #{found ? "trouvé" : "non trouvé"} — #{answer}" }.join(" ; ")}
        end
      end
      sleep 30.seconds
      {"das2" => {das2_account, das2_siren}, "liasse" => {liasse_account, liasse_siren}}.each do |kind, (account, siren)|
        Explore.attempt(section, "L3 déclarations listées 30 s après (#{kind})") do
          next {nil.as(Bool?), "dépôt #{kind} refusé : rien à lister"} unless deposited[kind]?
          found, detail = Explore.declarations(client, account, siren)
          {found.as(Bool?), detail}
        end
      end
    end

    it "10. Lien ouvert : la DAS2 n'existe-t-elle chez TELEDEC qu'une fois son lien ouvert ?" do
      Sandbox.require_stage!
      Sandbox.account!
      section = "Lien ouvert"
      siren = Explore.siren(62)
      credentials = Sandbox.credentials(siret: Explore.siret(siren))
      lister = Explore.list_client(credentials)
      client = lister || Explore::Client.adapter(credentials)
      account = Explore.create_company(siren, "ISRS")
      params = {"email" => account, "siren" => siren, "date_fin" => "2025-12-31", "formulaire" => "DAS2"}
      link = nil
      Explore.attempt(section, "O0 dépôt de la DAS2 (ISRS, régime dans l'identité, lien demandé)") do
        response = client.post(Explore::WHITE_LABEL, Explore.das2_document(siren, account).to_json)
        accepted, detail = Explore.white_label_outcome(response)
        link = (JSON.parse(response.body)["lien"]?.try(&.as_s?) rescue nil) if accepted
        {accepted.as(Bool?), detail}
      end
      opened = link
      unless opened
        Explore.attempt(section, "O1–O4") { {nil.as(Bool?), "pas de lien rendu : rien à ouvrir"} }
        next
      end
      look = ->(tag : String) do
        Explore.attempt(section, "#{tag} suivi (paramètres de l'adaptateur)") do
          found, detail = Explore.status_answer(client, params)
          {found.as(Bool?), "#{found ? "trouvé" : "non trouvé"} — #{detail}"}
        end
        Explore.attempt(section, "#{tag} déclarations listées") do
          next {nil.as(Bool?), "droit liste-declarations refusé : liste non interrogée"} unless lister
          found, detail = Explore.declarations(lister, account, siren)
          {found.as(Bool?), detail}
        end
      end
      look.call("O1 avant l'ouverture :")
      Explore.attempt(section, "O2 ouverture du lien (GET seuls, redirections suivies, rien cliqué)") do
        accepted, detail = Explore.open_link(opened)
        {accepted.as(Bool?), detail}
      end
      look.call("O3 aussitôt après l'ouverture :")
      sleep 10.seconds
      look.call("O4 10 s après l'ouverture :")
    end
  else
    pending "exploration désactivée (TELEDEC_EXPLORATION=1 et identifiants du stage requis)"
  end
end

# Tableau des variantes jouées, en fin de suite (quel que soit l'ordre des
# exemples) : affiché et écrit dans un fichier lisible du seul utilisateur.
if Explore.enabled?
  Spec.after_suite do
    next if Explore.outcomes.empty?
    path = Explore.write_report
    STDOUT.puts
    STDOUT.puts Explore.report
    STDOUT.puts "  Tableau écrit dans #{path} (droits 0600) : à transmettre tel quel."
    STDOUT.flush
  end
end
