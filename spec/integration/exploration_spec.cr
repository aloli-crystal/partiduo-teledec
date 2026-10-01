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

  # Client brut du stage : jeton obtenu par l'adaptateur réel (droits
  # facultatifs compris, avec son repli), puis requêtes libres.
  class Client
    getter scopes : Array(String)
    @token : String

    def initialize(credentials : Credentials)
      capture = TokenCapture.new
      Sandbox.transport(capture).check(credentials)
      @token = JSON.parse(capture.token_body)["access_token"].as_s
      @scopes = URI::Params.parse(capture.token_request)["scope"]?.to_s.split(' ').map(&.lchop("stage/"))
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
    params = URI::Params.build do |query|
      query.add "email", email
      query.add "siren", siren
      query.add "date_fin", date_fin
      query.add "formulaire", form
    end
    response = client.get("/service/declaration-status?#{params}")
    "suivi HTTP #{response.status} : #{message(response)}"
  end

  # --- Entreprises de test ------------------------------------------------------

  def self.identity(siren : String, legal_form : String = "SAS") : Payload::Identity
    Payload::Identity.new("PARTIDUO EXPLORATION #{siren[-3..]}", legal_form, siren, "", "", "1000.00", "3 rue des Lilas",
      "69003", "Lyon", "FR", Sandbox::EMAIL)
  end

  # Crée l'entreprise et son compte (`creation-entreprise`), régime
  # `regime` (`nil` : champ omis).
  def self.create_company(siren : String, regime : String?, legal_form : String = "SAS") : String
    account = Sandbox.transport.account_email(siren)
    company = {"siren" => siren, "name" => "PARTIDUO EXPLORATION #{siren[-3..]}", "yearEndMonth" => 12, "yearEndDay" => 31,
               "addressStreet" => "3 rue des Lilas", "addressPostalCode" => "69003", "addressCity" => "Lyon",
               "addressCountry" => "FR", "legalForm" => legal_form, "regimeFiscalTVA" => "Normal"} of String => String | Int32
    regime.try { |value| company["fullRegimeFiscal"] = value }
    Sandbox.transport.create_company(Sandbox.credentials(siret: siret(siren)), company, Sandbox.password_hash, account)
    account
  end

  def self.submission(payload : Payload, due_on : String? = nil) : Submission
    Submission.new("partiduo-exploration-#{payload.identity.siren}-#{Time.utc.to_unix}", payload.kind, payload.forms,
      payload.to_json, payload.fingerprint, due_on: due_on, year_end: "2025-12-31")
  end

  def self.offline_credentials(siren : String) : Credentials
    Credentials.new("x", "y", "sandbox", Sandbox::EMAIL, siret(siren))
  end

  # Document DAS2 de 2025 de l'adaptateur pour l'entreprise `siren`.
  def self.das2_document(siren : String, account : String) : Hash(String, JSON::Any)
    lines = Sandbox.das2_payload.das2 || [] of Payload::Das2Line
    payload = Payload.new("das2", ["DAS2"], identity(siren), "2025-01-01", "2025-12-31", 0, nil, nil, nil, lines,
      {"threshold" => "1200"})
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

  def self.edit(document : Hash(String, JSON::Any), block : String, & : Hash(String, JSON::Any) -> _) : Hash(String, JSON::Any)
    part = document[block].as_h.dup
    yield part
    document.merge({block => JSON::Any.new(part)})
  end

  WHITE_LABEL = "/service/declaration-marque-blanche"
end

private alias Explore = Teledec::Exploration
private alias Sandbox = Teledec::SandboxSpec

describe "Exploration du stage de TELEDEC (optionnelle)" do
  it "forme des SIREN et des SIRET fictifs à clé valide, distincts" do
    sirens = (1..12).map { |number| Explore.siren(number) }
    sirens.uniq.size.should eq(12)
    sirens.all? { |siren| siren.size == 9 && siren.starts_with?("998") && Explore.luhn?(siren) }.should be_true
    sirens.all? { |siren| Explore.luhn?(Explore.siret(siren)) && Explore.siret(siren).size == 14 }.should be_true
    Explore.luhn?(Sandbox::SIREN).should be_true # entreprise de la suite du stage
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
      client = Explore::Client.new(Sandbox.credentials)
      section = "DAS2"
      dated = ->(siren : String, document : Hash(String, JSON::Any), account : String) do
        response = client.post(Explore::WHITE_LABEL, document.to_json)
        accepted, detail = Explore.white_label_outcome(response)
        detail += " ; " + Explore.state(client, account, siren, "2025-12-31", "DAS2") if accepted
        {accepted.as(Bool?), detail}
      end

      Explore.attempt(section, "D1 adaptateur actuel : entreprise ISRS, DAS2 seule, millésime 2026") do
        siren = Explore.siren(1)
        account = Explore.create_company(siren, "ISRS")
        dated.call(siren, Explore.das2_document(siren, account), account)
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
        document = Explore.edit(Explore.das2_document(siren, account), "identity") { |part| part["fullRegimeFiscal"] = JSON::Any.new("ISRS") }
        dated.call(siren, document, account)
      end
      Explore.attempt(section, "D5 entreprise ISRN (régime réel normal)") do
        siren = Explore.siren(5)
        account = Explore.create_company(siren, "ISRN")
        dated.call(siren, Explore.das2_document(siren, account), account)
      end
      Explore.attempt(section, "D6 entreprise BICRS (IR)") do
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
      section = "Greffe"
      siren = Explore.siren(20)
      account = Explore.create_company(siren, "ISRS", "SAS")
      client = Explore::Client.new(Sandbox.credentials(siret: Explore.siret(siren)))
      payload = Teledec::Payload.new("greffe", ["greffe"], Explore.identity(siren), "2025-01-01", "2025-12-31", 0, nil,
        nil, nil, nil, {"confidential" => "0"})
      full = JSON.parse(Teledec::Remote::Formats.greffe(payload, Explore.submission(payload),
        Explore.offline_credentials(siren), Time.utc, account)).as_h
      auth = full["auth"].as_h
      bodies = [
        {"G1 minimal : formulaire seul", {"formulaire" => full["formulaire"]}},
        {"G2 + auth.email et timestamp", {"formulaire" => full["formulaire"],
                                          "auth"       => JSON::Any.new(auth.select("email", "timestamp"))}},
        {"G3 + identity", {"formulaire" => full["formulaire"], "auth" => JSON::Any.new(auth.select("email", "timestamp")),
                           "identity" => full["identity"]}},
        {"G4 + period", {"formulaire" => full["formulaire"], "auth" => JSON::Any.new(auth.select("email", "timestamp")),
                         "identity" => full["identity"], "period" => full["period"]}},
        {"G5 + auth.url et retournerLien (corps de l'adaptateur)",
         full.merge({"auth" => JSON::Any.new(auth.merge({"url" => JSON::Any.new("https://exemple.invalid/hooks/TELEDEC/callback")}))})},
      ]
      bodies.each do |(variant, body)|
        Explore.attempt(section, variant) do
          unless client.scopes.includes?("nouvelle-declaration")
            next {nil.as(Bool?), "droit nouvelle-declaration absent du jeton (refusé par le service des jetons)"}
          end
          response = client.post("/service/nouvelle-declaration", body.to_json)
          url = Teledec::Remote::Formats.redirect_url(response.body)
          if response.ok? && !url.empty?
            {true.as(Bool?), "HTTP #{response.status}, adresse rendue : #{Sandbox.truncated(url)}"}
          else
            {false.as(Bool?), "HTTP #{response.status} : #{Explore.message(response)}"}
          end
        end
      end
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
          client = Explore::Client.new(Sandbox.credentials(siret: Explore.siret(siren)))
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
