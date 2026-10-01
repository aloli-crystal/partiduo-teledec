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
# Troisième série (D-TDC11-003, jetons de la liste, liste des
# déclarations, lien ouvert) : jouée le 1er octobre 2026, tranchée
# (D-TDC12-001, D-TDC12-002) et retirée.
#
# Quatrième série (D-TDC12-004), après la troisième :
#
# 11. *Suivi de la DAS2 sous la liasse* : DAS2 déposée, puis
#    `declaration-status` avec `formulaire=liasse` et `date_fin` au
#    31 décembre de son année (AAAA-MM-JJ), aussitôt et par l'adaptateur
#    (suivi, puis secours par la liste).
# 12. *Liasse par l'API Balance, lien ouvert* : liasse déposée, ouverture
#    (`GET` seuls, redirections suivies, sur le stage seulement, rien
#    cliqué) de son adresse, puis liste et `declaration-status`
#    (`formulaire=liasse`) aussitôt et 10 s après.
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
  LIST_SCOPE = HttpTransport::LIST_SCOPE

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

  # Ouvre l'adresse rendue par TELEDEC (marque blanche, liasse) comme un navigateur : `GET`
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
    numbers = (1..14).to_a + [20, 21, 30, 31] + (40..47).to_a + [50, 51] + (60..62).to_a + [70, 71]
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
    # Les séries 1 à 7 (DAS2 seule, greffe, liasse #CREATION-AUTO, régimes,
    # BICRS, noms du droit du greffe, délais du suivi) ont été jouées sur le
    # stage les 1er octobre 2026 ; leurs résultats sont tranchés et consignés
    # (DECISIONS D-TDC10-*, D-TDC11-*, B-TDC-004) : elles sont retirées pour ne
    # pas rejouer des essais conclus.

    # La troisième série (jetons de la liste, liste des déclarations, lien
    # ouvert, D-TDC11-003) a été jouée le 1er octobre 2026 ; ses résultats
    # sont tranchés et consignés (DECISIONS D-TDC12-001, D-TDC12-002) : elle
    # est retirée elle aussi.

    # --- Quatrième série (D-TDC12-004) ----------------------------------------------

    it "11. Suivi de la DAS2 sous la déclaration liasse de son année" do
      Sandbox.require_stage!
      Sandbox.account!
      section = "Suivi DAS2"
      siren = Explore.siren(70)
      credentials = Sandbox.credentials(siret: Explore.siret(siren))
      client = Explore.list_client(credentials) || Explore::Client.adapter(credentials)
      account = Explore.create_company(siren, "ISRS")
      deposited = false
      Explore.attempt(section, "S0 dépôt de la DAS2 (ISRS, régime dans l'identité)") do
        response = client.post(Explore::WHITE_LABEL, Explore.das2_document(siren, account).to_json)
        accepted, detail = Explore.white_label_outcome(response)
        deposited = accepted
        {accepted.as(Bool?), detail}
      end
      unless deposited
        Explore.attempt(section, "S1–S2") { {nil.as(Bool?), "DAS2 refusée : rien à suivre"} }
        next
      end
      Explore.attempt(section, "S1 declaration-status, formulaire=liasse, date_fin=2025-12-31, aussitôt") do
        params = {"email" => account, "siren" => siren, "date_fin" => "2025-12-31", "formulaire" => "liasse"}
        found, detail = Explore.status_answer(client, params)
        {found.as(Bool?), "#{found ? "trouvé" : "non trouvé"} — #{detail}"}
      end
      Explore.attempt(section, "S2 suivi de l'adaptateur (liasse, puis secours par la liste)") do
        status = Sandbox.transport.status(credentials, "DAS2:#{siren}:2025-12-31")
        {(status.remote_status != "notfound").as(Bool?),
         "état #{status.state}, statut brut « #{status.remote_status} », déclaration #{status.declaration_id.presence || "inconnue"}"}
      end
    end

    it "12. Liasse par l'API Balance : lien ouvert, puis liste et suivi" do
      Sandbox.require_stage!
      Sandbox.account!
      section = "Liasse ouverte"
      siren = Explore.siren(71)
      credentials = Sandbox.credentials(siret: Explore.siret(siren))
      lister = Explore.list_client(credentials)
      client = lister || Explore::Client.adapter(credentials)
      account = Explore.create_company(siren, "ISRS")
      url = nil
      Explore.attempt(section, "B0 dépôt de la liasse (creation-entreprise avant)") do
        base = Sandbox.liasse_payload
        payload = Teledec::Payload.new("liasse", base.forms, Explore.identity(siren), base.period_from,
          base.period_to, 0, base.balance)
        source = Sandbox.instance_setting("TELEDEC_SOURCE") || "API"
        body = Teledec::Remote::Formats.liasse(payload, Explore.submission(payload), credentials, source, false, account)
        response = client.post("/service/liasse", body, "text/plain; charset=utf-8")
        link = Teledec::Remote::Formats.redirect_url(response.body)
        url = link unless link.empty?
        accepted = response.ok? && !link.empty?
        {accepted.as(Bool?), accepted ? "liasse acceptée, adresse rendue" : "HTTP #{response.status} : #{Explore.message(response)}"}
      end
      opened = url
      unless opened
        Explore.attempt(section, "B1–B3") { {nil.as(Bool?), "pas d'adresse rendue : rien à ouvrir"} }
        next
      end
      date_fin = Sandbox.liasse_payload.period_to
      look = ->(tag : String) do
        Explore.attempt(section, "#{tag} déclarations listées") do
          next {nil.as(Bool?), "droit liste-declarations refusé : liste non interrogée"} unless lister
          found, detail = Explore.declarations(lister, account, siren)
          {found.as(Bool?), detail}
        end
        Explore.attempt(section, "#{tag} declaration-status, formulaire=liasse, date_fin=#{date_fin}") do
          params = {"email" => account, "siren" => siren, "date_fin" => date_fin, "formulaire" => "liasse"}
          found, detail = Explore.status_answer(client, params)
          {found.as(Bool?), "#{found ? "trouvé" : "non trouvé"} — #{detail}"}
        end
      end
      Explore.attempt(section, "B1 ouverture de l'adresse (GET seuls, redirections suivies, rien cliqué)") do
        accepted, detail = Explore.open_link(opened)
        {accepted.as(Bool?), detail}
      end
      look.call("B2 aussitôt après l'ouverture :")
      sleep 10.seconds
      look.call("B3 10 s après l'ouverture :")
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
