# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Remote = Teledec::Remote

# Échange scripté : rend, pour chaque chemin, les réponses programmées dans
# l'ordre (la dernière se répète) ; le jeton est accordé par défaut.
private class ScriptedExchange < Remote::Exchange
  getter requests = [] of Remote::Request
  getter scripts = {} of String => Array(Remote::Response)

  def initialize
    script("/oauth2/token", 200, %({"access_token": "jeton-1", "expires_in": 3600}))
  end

  def script(path : String, status : Int32, body : String) : self
    (@scripts[path] ||= [] of Remote::Response) << Remote::Response.new(status, body, "application/json")
    self
  end

  def reset(path : String) : self
    @scripts.delete(path)
    self
  end

  def call(request : Remote::Request) : Remote::Response
    @requests << request
    list = @scripts[request.path]? || return Remote::Response.new(599, "aucune réponse programmée")
    list.size > 1 ? list.shift : list.first
  end

  def count(path : String) : Int32
    @requests.count(&.path.==(path))
  end
end

private def credentials(email : String = "compta@atelier-brunet.test", env : String = "sandbox",
                        siret : String = "73282932000074", password_hash : String = "$2a$12$empreinte",
                        account_ready : Bool = true) : Teledec::Credentials
  Teledec::Credentials.new("client-id", "secret-client", env, email, siret, password_hash: password_hash,
    account_ready: account_ready)
end

private def payload(kind : String, legal_form : String = "SARL") : String
  identity = Teledec::Payload::Identity.new("Atelier Brunet SARL", legal_form, "732829320", "", "", nil, "", "69002", "Lyon",
    "FR", "")
  boxes = kind == "vat_ca3" ? {"3310-CA3" => {"08.base" => "100", "08.tax" => "20", "32" => "20"}} : nil
  Teledec::Payload.new(kind, [kind], identity, "2026-03-01", "2026-03-31", boxes: boxes).to_json
end

private def submission(kind : String, body : String = payload(kind)) : Teledec::Submission
  Teledec::Submission.new("partiduo-1-1-abc", kind, [kind], body, "abc", due_on: "2026-04-19")
end

private def transport(exchange : ScriptedExchange) : Teledec::HttpTransport
  Teledec::HttpTransport.new(exchange, source: "PARTIDUO", clock: -> { Time.utc(2026, 4, 1, 8, 0) },
    user_domain: "partiduo.test")
end

private def error_of(& : -> _) : Teledec::TransportError
  expect_raises(Teledec::TransportError) { yield }
end

describe "Adaptateur HTTP de TELEDEC : jeton, erreurs et réponses inattendues" do
  it "traduit les refus du serveur d'autorisation" do
    {400 => "teledec.errors.transport.credentials", 401 => "teledec.errors.transport.credentials",
     403 => "teledec.errors.transport.credentials", 500 => "teledec.errors.transport.unreachable"}.each do |status, key|
      exchange = ScriptedExchange.new.reset("/oauth2/token").script("/oauth2/token", status, %({"error": "x"}))
      error_of { transport(exchange).check(credentials) }.key.should eq(key)
    end
    exchange = ScriptedExchange.new.reset("/oauth2/token").script("/oauth2/token", 200, %({"token_type": "Bearer"}))
    error_of { transport(exchange).check(credentials) }.key.should eq("teledec.errors.transport.credentials")
    exchange = ScriptedExchange.new.reset("/oauth2/token").script("/oauth2/token", 200, "<html>")
    error_of { transport(exchange).check(credentials) }.key.should eq("teledec.errors.transport.invalid")
  end

  it "refuse un environnement inconnu sans rien envoyer" do
    exchange = ScriptedExchange.new
    error_of { transport(exchange).check(credentials(env: "lune")) }.key.should eq("teledec.errors.credentials.env")
    exchange.requests.should be_empty
  end

  it "redemande le jeton quand il expire (marge d'une minute), durée donnée en texte ou absente" do
    exchange = ScriptedExchange.new.reset("/oauth2/token")
      .script("/oauth2/token", 200, %({"access_token": "court", "expires_in": 30}))
      .script("/oauth2/token", 200, %({"access_token": "long", "expires_in": "7200"}))
    exchange.script("/service/declaration-status", 404, %({"message": "declaration not found"}))
    adapter = transport(exchange)
    adapter.check(credentials)
    adapter.status(credentials, "liasse:732829320:2026-12-31")
    exchange.count("/oauth2/token").should eq(2) # 30 s < marge : jeton déjà périmé
    adapter.status(credentials, "liasse:732829320:2026-12-31")
    exchange.count("/oauth2/token").should eq(2)
    exchange.requests.last.headers["Authorization"].should eq("Bearer long")
    # Autre compte : autre jeton.
    adapter.check(Teledec::Credentials.new("autre", "cle", "sandbox"))
    exchange.count("/oauth2/token").should eq(3)
  end

  it "ne rejoue qu'une fois un appel refusé en 401, puis signale les identifiants" do
    exchange = ScriptedExchange.new.script("/service/declaration-status", 401, %({"message": "Unauthorized"}))
    error_of { transport(exchange).status(credentials, "liasse:732829320:2026-12-31") }.key
      .should eq("teledec.errors.transport.credentials")
    exchange.count("/service/declaration-status").should eq(2)
    exchange.count("/oauth2/token").should eq(2)
    exchange = ScriptedExchange.new.script("/service/declaration-status", 403, "Forbidden")
    error_of { transport(exchange).status(credentials, "liasse:732829320:2026-12-31") }.key
      .should eq("teledec.errors.transport.credentials")
    exchange.count("/service/declaration-status").should eq(1)
  end

  it "classe les autres erreurs : panne technique, compte inconnu, source, refus avec motif abrégé" do
    exchange = ScriptedExchange.new.script("/service/declaration-status", 500, %({"message": "Erreur technique"}))
    error_of { transport(exchange).status(credentials, "liasse:732829320:2026-12-31") }.key
      .should eq("teledec.errors.transport.unreachable")
    exchange = ScriptedExchange.new.script("/service/declaration-status", 400, %({"erreur": "Utilisateur non trouvé"}))
    account = error_of { transport(exchange).status(credentials, "liasse:732829320:2026-12-31") }
    account.key.should eq("teledec.errors.transport.account")
    account.params["reason"].should eq("Utilisateur non trouvé")
    exchange = ScriptedExchange.new.script("/service/liasse", 400, %({"message": "La source n'est pas reconnue"}))
    error_of { transport(exchange).submit(credentials, submission("liasse")) }.key.should eq("teledec.errors.transport.source")
    long = "Montant   incohérent\n" + "x" * 400
    exchange = ScriptedExchange.new.script("/service/declaration-marque-blanche", 500, {"message" => long}.to_json)
    refused = error_of { transport(exchange).submit(credentials, submission("vat_ca3")) }
    refused.key.should eq("teledec.errors.transport.refused")
    refused.params["reason"].should start_with("Montant incohérent x")
    refused.params["reason"].size.should eq(301)
    refused.params["reason"].should end_with("…")
    # « Ressource » n'est pas la source de la liasse ; une autre erreur 101
    # non plus.
    exchange = ScriptedExchange.new.script("/service/liasse", 500, %({"message": "Ressource introuvable"}))
    error_of { transport(exchange).submit(credentials, submission("liasse")) }.key.should eq("teledec.errors.transport.refused")
    exchange = ScriptedExchange.new.script("/service/liasse", 500, "erreur 101 : l'email renseigné 'x' est invalide.")
    error_of { transport(exchange).submit(credentials, submission("liasse")) }.key.should eq("teledec.errors.transport.refused")
    exchange = ScriptedExchange.new.script("/service/liasse", 500, "Source non reconnue")
    error_of { transport(exchange).submit(credentials, submission("liasse")) }.key.should eq("teledec.errors.transport.source")
    exchange = ScriptedExchange.new.script("/service/liasse", 422, "texte brut")
    error_of { transport(exchange).submit(credentials, submission("liasse")) }.params["reason"].should eq("texte brut")
  end

  it "exige le domaine du partenaire, le haché du mot de passe et un document lisible avant tout envoi" do
    exchange = ScriptedExchange.new
    no_domain = Teledec::HttpTransport.new(exchange, source: "API")
    no_domain.user_domain.should be_nil
    error_of { no_domain.submit(credentials, submission("vat_ca3")) }.key.should eq("teledec.errors.transport.user_domain")
    error_of { no_domain.status(credentials, "liasse:732829320:2026-12-31") }.key
      .should eq("teledec.errors.transport.user_domain")
    error_of { transport(exchange).submit(credentials(password_hash: ""), submission("vat_ca3")) }.key
      .should eq("teledec.errors.transport.password")
    error_of { transport(exchange).submit(credentials, submission("greffe", payload("greffe", "SCI"))) }.key
      .should eq("teledec.errors.transport.greffe_legal_form")
    exchange.requests.should be_empty
    error_of { transport(exchange).submit(credentials, submission("vat_ca3", "{pas du json")) }.key
      .should eq("teledec.errors.transport.invalid")
    error_of { transport(exchange).submit(credentials, submission("vat_ca3", %({"kind": "vat_ca3"}))) }.key
      .should eq("teledec.errors.transport.invalid")
    error_of { transport(exchange).submit(credentials(siret: "40483304800006"), submission("liasse")) }.key
      .should eq("teledec.errors.transport.siret")
    exchange.requests.should be_empty
  end

  it "lit l'adresse de la liasse en texte ou en JSON, et rien d'autre" do
    {"https://stage.teledec.fr/liasse/42\nsuite"       => "https://stage.teledec.fr/liasse/42",
     %({"url": "https://stage.teledec.fr/liasse/43"})  => "https://stage.teledec.fr/liasse/43",
     %({"lien": "https://stage.teledec.fr/liasse/44"}) => "https://stage.teledec.fr/liasse/44",
     "OK"                                              => ""}.each do |body, url|
      exchange = ScriptedExchange.new.script("/service/liasse", 200, body)
      submitted = transport(exchange).submit(credentials, submission("liasse"))
      submitted.url.should eq(url)
      submitted.remote_id.should eq("liasse:732829320:2026-03-31")
      submitted.remote_status.should eq("notcompleted")
    end
  end

  it "signale un refus de la marque blanche rendu en 200, et une réponse qui n'est pas un objet" do
    exchange = ScriptedExchange.new.script("/service/declaration-marque-blanche", 200, %({"message": "Période déjà déclarée"}))
    refused = error_of { transport(exchange).submit(credentials, submission("vat_ca3")) }
    refused.key.should eq("teledec.errors.transport.refused")
    refused.params["reason"].should eq("Période déjà déclarée")
    exchange = ScriptedExchange.new.script("/service/declaration-marque-blanche", 200, "[]")
    error_of { transport(exchange).submit(credentials, submission("vat_ca3")) }.key.should eq("teledec.errors.transport.invalid")
    exchange = ScriptedExchange.new.script("/service/declaration-marque-blanche", 200, "{}")
    submitted = transport(exchange).submit(credentials, submission("vat_ca3"))
    submitted.url.should eq("")
    submitted.remote_id.should eq("3310CA3:732829320:2026-03-31:2026-04-19")
    exchange.requests.last.headers["Content-Type"].should eq("application/json")
    exchange.requests.last.url.should eq("https://stage.teledec.fr/service/declaration-marque-blanche")
  end

  it "vise www.teledec.fr en production" do
    exchange = ScriptedExchange.new.script("/service/declaration-status", 404, "{}")
      .script("/service/declarations", 404, %({"message": "Aucune déclaration trouvée"}))
    transport(exchange).status(credentials(env: "production"), "liasse:732829320:2026-12-31").remote_status.should eq("notfound")
    tracked = exchange.requests.find!(&.path.==("/service/declaration-status"))
    tracked.url.should start_with("https://www.teledec.fr/service/declaration-status?")
    tracked.query_params["email"].should eq("teledec-732829320@partiduo.test")
    tracked.query_params["formulaire"].should eq("liasse")
    tracked.query_params["date_echeance"]?.should be_nil
    # Introuvable par le suivi : la liste des déclarations, sur la même base.
    exchange.requests.last.url.should start_with("https://www.teledec.fr/service/declarations?")
  end

  it "suit la DAS2 sous la liasse de son année ; introuvable (400 ou 404), la lit dans la liste des déclarations" do
    listed = <<-JSON
      [{"id": 286182, "label": "Liasse fiscale 2025", "declarationType": "Liasse", "dateDebut": "2025-01-01",
        "dateFin": "2025-12-31", "status": "Created", "lienDeclaration": "https://stage.teledec.fr/service/declaration/eyJjeton"}]
      JSON
    exchange = ScriptedExchange.new.script("/service/declaration-status", 400, %({"message": "formulaire inconnu"}))
      .script("/service/declarations", 200, listed)
    status = transport(exchange).status(credentials, "DAS2:732829320:2025-12-31")
    {status.state, status.remote_status, status.declaration_id}.should eq({"pending", "created", "286182"})
    tracked = exchange.requests.find!(&.path.==("/service/declaration-status")).query_params
    {tracked["formulaire"], tracked["date_fin"]}.should eq({"liasse", "2025-12-31"})
    listing = exchange.requests.last.query_params
    {listing["siren"], listing["email"]}.should eq({"732829320", "teledec-732829320@partiduo.test"})
    status.inspect.should_not contain("eyJ")
    # Compte inconnu : une erreur, jamais un dépôt introuvable.
    exchange = ScriptedExchange.new.script("/service/declaration-status", 400, "Utilisateur non trouvé pour l'email fourni")
    error_of { transport(exchange).status(credentials, "DAS2:732829320:2025-12-31") }.key.should eq("teledec.errors.transport.account")
    exchange.count("/service/declarations").should eq(0)
    # Hors DAS2, un 400 reste un refus.
    exchange = ScriptedExchange.new.script("/service/declaration-status", 400, %({"message": "paramètre manquant"}))
    error_of { transport(exchange).status(credentials, "liasse:732829320:2025-12-31") }.key.should eq("teledec.errors.transport.refused")
    # Liste refusée ou illisible : en attente, sans erreur.
    exchange = ScriptedExchange.new.script("/service/declaration-status", 404, "{}").script("/service/declarations", 200, "{}")
    transport(exchange).status(credentials, "DAS2:732829320:2025-12-31").remote_status.should eq("notfound")
  end

  it "suit un dépôt : identifiant illisible, en attente, accusé avec PDF, rejet sans compte-rendu" do
    exchange = ScriptedExchange.new
    error_of { transport(exchange).status(credentials, "TD-1") }.key.should eq("teledec.errors.transport.invalid")

    exchange.script("/service/declaration-status", 200, %({"status": "Sent"}))
    pending = transport(exchange).status(credentials, "liasse:732829320:2026-12-31")
    pending.state.should eq("pending")
    pending.remote_status.should eq("sent")

    pdf = Base64.strict_encode("%PDF-1.4 accusé")
    exchange.reset("/service/declaration-status").script("/service/declaration-status", 200,
      %({"status": "OK", "compteRendus": [{"declarationId": 99, "status": "OK", "pdf": "#{pdf}", "dateHeureDGFiP": "2027-05-02T09:00:00"}]}))
    done = transport(exchange).status(credentials, "2571:732829320:2026-12-31:2026-03-15")
    done.state.should eq("acknowledged")
    done.declaration_id.should eq("99")
    done.at.should eq(Time.utc(2027, 5, 2, 7, 0))
    receipt = done.receipt || raise "accusé absent"
    receipt.filename.should eq("accuse-2571-732829320-2026-12-31.pdf")
    String.new(receipt.content).should eq("%PDF-1.4 accusé")
    exchange.count("/service/recuperation-liste-compterendus").should eq(0)

    exchange.reset("/service/declaration-status").script("/service/declaration-status", 200,
      %({"status": "ERREUR", "message": "Rejet de la DGFiP"}))
    exchange.script("/service/recuperation-liste-compterendus", 404, %({"message": "aucun"}))
    rejected = transport(exchange).status(credentials, "liasse:732829320:2026-12-31")
    rejected.state.should eq("rejected")
    rejected.reason.should eq("Rejet de la DGFiP")
    rejected.receipt.should be_nil
    rejected.declaration_id.should eq("")
  end

  it "ne retient ni le compte-rendu d'un envoi précédent ni celui d'un paiement" do
    exchange = ScriptedExchange.new.script("/service/declaration-status", 200,
      %({"status": "ERREUR", "compteRendus": [{"reference": "partiduo-1-1-abc", "status": "ERREUR", "erreurLibelle": "ancien"}]}))
    stale = transport(exchange).status(credentials, "liasse:732829320:2026-12-31", "partiduo-1-2-def")
    stale.state.should eq("pending")
    stale.reason.should eq("")
    stale.remote_status.should eq("")
    # Même compte-rendu pour l'envoi qu'il concerne : rejet.
    transport(exchange).status(credentials, "liasse:732829320:2026-12-31", "partiduo-1-1-abc").state.should eq("rejected")
    # Sans référence attendue (appel direct) : il fait foi.
    transport(exchange).status(credentials, "liasse:732829320:2026-12-31").state.should eq("rejected")

    answer = <<-JSON
      {"status": "OK", "compteRendus": [
        {"reference": "r", "declarationType": "TVA", "status": "OK", "dateHeureDGFiP": "2027-05-02T09:00:00"},
        {"reference": "r", "declarationType": "Paiement", "status": "ERREUR", "erreurLibelle": "prélèvement refusé",
         "dateHeureDGFiP": "2027-05-03T09:00:00"}]}
      JSON
    exchange = ScriptedExchange.new.script("/service/declaration-status", 200, answer)
    done = transport(exchange).status(credentials, "3310CA3:732829320:2026-03-31:2026-04-19", "r")
    done.state.should eq("acknowledged")
    done.reason.should eq("")
  end

  it "lit la liste des comptes-rendus, en tableau ou sous compteRendus" do
    exchange = ScriptedExchange.new.script("/service/recuperation-liste-compterendus", 200, %([{"status": "OK"}]))
    key = Remote::Formats::Key.new("liasse", "732829320", "2026-12-31")
    transport(exchange).reports(credentials, key).map(&.state).should eq(["acknowledged"])
    exchange.reset("/service/recuperation-liste-compterendus")
      .script("/service/recuperation-liste-compterendus", 200, %({"compteRendus": [{"status": "ERREUR"}, {"status": "OK"}]}))
    transport(exchange).reports(credentials, key).map(&.state).should eq(%w[rejected acknowledged])
    exchange.reset("/service/recuperation-liste-compterendus").script("/service/recuperation-liste-compterendus", 200, %({"x": 1}))
    transport(exchange).reports(credentials, key).should be_empty
  end

  it "crée l'entreprise avec le haché du mot de passe, jamais un mot de passe en clair" do
    exchange = ScriptedExchange.new.script("/service/creation-entreprise", 200, %({"id": 5}))
    adapter = transport(exchange)
    adapter.create_company(credentials, {"siret" => "73282932000074", "yearEndMonth" => 12}, "$2y$12$empreinte",
      "teledec-732829320@partiduo.test").should eq(%({"id": 5}))
    body = JSON.parse(exchange.requests.last.body)
    body["auth"]["password"].as_s.should eq("$2y$12$empreinte")
    body["auth"]["email"].as_s.should eq("teledec-732829320@partiduo.test")
    body["identity"]["yearEndMonth"].as_i.should eq(12)
    error_of { adapter.create_company(credentials, {} of String => String | Int32, "en-clair", "a@b.test") }.key
      .should eq("teledec.errors.transport.password")
  end

  it "crée le compte de l'entreprise avant sa première déclaration en marque blanche, une fois" do
    exchange = ScriptedExchange.new.script("/service/creation-entreprise", 200, "ok")
      .script("/service/declaration-marque-blanche", 200, %({"lien": "https://stage.teledec.fr/d/1"}))
    adapter = transport(exchange)
    first = adapter.submit(credentials(account_ready: false), submission("vat_ca3"))
    first.account_created.should be_true
    exchange.requests.map(&.path).should eq(["/oauth2/token", "/service/creation-entreprise",
                                             "/service/declaration-marque-blanche"])
    created = JSON.parse(exchange.requests[1].body)
    created["auth"]["email"].as_s.should eq("teledec-732829320@partiduo.test")
    created["identity"]["siren"].as_s.should eq("732829320")
    document = JSON.parse(exchange.requests.last.body)
    document["auth"]["email"].as_s.should eq("teledec-732829320@partiduo.test")
    document["identity"]["email"].as_s.should eq("compta@atelier-brunet.test")
    adapter.submit(credentials, submission("vat_ca3")).account_created.should be_false
    exchange.count("/service/creation-entreprise").should eq(1)
  end

  it "crée le compte et l'entreprise, à son régime, avant la première liasse (la liasse ne le crée pas)" do
    exchange = ScriptedExchange.new.script("/service/creation-entreprise", 200, "ok")
      .script("/service/liasse", 200, "https://stage.teledec.fr/liasse/7")
    adapter = transport(exchange)
    identity = Teledec::Payload::Identity.new("Cabinet Morel", "EI", "732829320", "", "", nil, "", "69002", "Lyon", "FR", "")
    body = Teledec::Payload.new("liasse", %w[2035], identity, "2025-01-01", "2025-12-31",
      boxes: {"2035-A" => {"AA" => "42000"}}).to_json
    liasse = Teledec::Submission.new("partiduo-1-2-abc", "liasse", %w[2035], body, "abc", year_end: "2025-12-31")
    adapter.submit(credentials(account_ready: false), liasse).account_created.should be_true
    exchange.requests.map(&.path).should eq(["/oauth2/token", "/service/creation-entreprise", "/service/liasse"])
    created = JSON.parse(exchange.requests[1].body)["identity"]
    created["fullRegimeFiscal"].as_s.should eq("BNCDC")
    created["regimeFiscalTVA"]?.should be_nil
    adapter.submit(credentials, liasse).account_created.should be_false
    exchange.count("/service/creation-entreprise").should eq(1)
  end

  it "prend la source dans PARTIDUO_TELEDEC_SOURCE, API à défaut, et masque le secret des identifiants" do
    previous = ENV["PARTIDUO_TELEDEC_SOURCE"]?
    begin
      ENV["PARTIDUO_TELEDEC_SOURCE"] = "CABINET"
      Teledec::HttpTransport.new(ScriptedExchange.new).source.should eq("CABINET")
      ENV["PARTIDUO_TELEDEC_SOURCE"] = ""
      Teledec::HttpTransport.new(ScriptedExchange.new).source.should eq("API")
    ensure
      previous ? (ENV["PARTIDUO_TELEDEC_SOURCE"] = previous) : ENV.delete("PARTIDUO_TELEDEC_SOURCE")
    end
    credentials.to_s.should_not contain("secret-client")
    credentials.inspect.should_not contain("secret-client")
  end

  it "rend une panne réseau en « injoignable »" do
    error = error_of { Remote::Net.new.call(Remote::Request.new("GET", "http://127.0.0.1:1/", HTTP::Headers.new)) }
    error.key.should eq("teledec.errors.transport.unreachable")
    error.message.should eq("teledec.errors.transport.unreachable")
  end

  it "borne la lecture d'une réponse de TELEDEC" do
    Remote::Net.read_limited(IO::Memory.new("abcd"), 4).should eq("abcd")
    Remote::Net.read_limited(nil, 4).should eq("")
    error_of { Remote::Net.read_limited(IO::Memory.new("abcde"), 4) }.key.should eq("teledec.errors.transport.invalid")
  end
end

describe "Régimes fiscaux envoyés à TELEDEC" do
  it "n'emploie que des valeurs de la liste de référence de TELEDEC" do
    Teledec::Remote::Formats::FULL_REGIMES.values.each do |regime|
      Teledec::Remote::Formats::KNOWN_REGIMES.includes?(regime).should be_true, regime
    end
  end
end
