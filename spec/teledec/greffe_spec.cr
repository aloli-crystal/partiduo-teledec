# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Teledec::SpecSupport
private alias Api = Teledec::Api
private alias Books = PartiduoUi::Books
private alias Formats = Teledec::Remote::Formats
private alias Remote = Teledec::Remote

# Échange scripté : réponses programmées par chemin (la dernière se
# répète) ; jeton accordé par défaut.
private class GreffeExchange < Remote::Exchange
  getter requests = [] of Remote::Request
  getter scripts = {} of String => Array(Remote::Response)

  def initialize
    script("/oauth2/token", 200, %({"access_token": "jeton-1", "expires_in": 3600}))
  end

  def script(path : String, status : Int32, body : String, type : String = "application/json") : self
    (@scripts[path] ||= [] of Remote::Response) << Remote::Response.new(status, body, type)
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

  def last(path : String) : Remote::Request
    @requests.reverse.find! { |request| request.path == path }
  end
end

private def credentials : Teledec::Credentials
  Teledec::Credentials.new("client-id", "secret-client", "sandbox", "compta@atelier-brunet.test", "73282932000074",
    password_hash: "$2a$12$empreinte", account_ready: true)
end

private def greffe_payload(legal_form : String = "SAS") : Teledec::Payload
  identity = Teledec::Payload::Identity.new("Atelier Brunet", legal_form, "732829320", "", "", nil, "3 rue des Lilas",
    "69003", "Lyon", "FR", "")
  Teledec::Payload.new("greffe", %w[greffe], identity, "2025-07-01", "2026-06-30", details: {"confidential" => "1"})
end

private def greffe_submission(payload : Teledec::Payload = greffe_payload) : Teledec::Submission
  Teledec::Submission.new("partiduo-7-1-abc", "greffe", %w[greffe], payload.to_json, payload.fingerprint,
    year_end: "2026-06-30", callback_url: "https://dossier.exemple.fr/hooks/TELEDEC/callback")
end

private def transport(exchange : Remote::Exchange) : Teledec::HttpTransport
  Teledec::HttpTransport.new(exchange, source: "API", clock: -> { Time.utc(2026, 10, 1, 8, 0) },
    user_domain: "partiduo.test")
end

private def error_of(& : -> _) : Teledec::TransportError
  expect_raises(Teledec::TransportError) { yield }
end

private def last_request(path : String) : Remote::Request
  S.teledec.requests.reverse.find! { |request| request.path == path }
end

# Dossier avec l'option du greffe, liasse de l'exercice transmise, dépôt au
# greffe préparé puis transmis (amorce) au TELEDEC simulé.
private def transmitted_greffe : Api::FilingView
  S.books(greffe: true)
  Books.sale(Books.card("CUSTOMER", "Atelier Morel").code, "1000")
  S.connect
  Api.transmit(S.admin, S.liasse.id).value!
  filing = S.prepare("greffe", fiscal_year_id: S.fiscal_year_id)
  filing.controls.map(&.key).should_not contain("teledec.controls.greffe_liasse")
  Api.transmit(S.admin, filing.id).value!
end

private GREFFE_ID = "greffe:732829320:2026-12-31"

describe "Dépôt au greffe par TELEDEC (réponses du 1er octobre 2026)" do
  describe "éligibilité" do
    it "n'admet que les formes juridiques qui déposent leurs comptes" do
      %w[SARL EURL SAS SASU SA SNC SCS SELARL S.A.R.L. sas selas].each do |form|
        {form, Teledec::Config.greffe_eligible?(form)}.should eq({form, true})
      end
      ["SCI", "EI", "EIRL", "Association", "ASSOCIATION", "SCM", "GIE", "EARL", "LMNP", "", "Société civile"].each do |form|
        {form, Teledec::Config.greffe_eligible?(form)}.should eq({form, false})
      end
    end

    it "refuse de préparer le greffe d'une SCI, d'une EI, d'une association ou d'une forme non renseignée (message traduit)" do
      S.books(greffe: true)
      {"SCI" => "teledec.errors.greffe.legal_form", "EI" => "teledec.errors.greffe.legal_form",
       "Association" => "teledec.errors.greffe.legal_form", "" => "teledec.errors.greffe.legal_form_missing"}.each do |form, key|
        S.legal_form(form)
        result = Api.prepare(S.admin, Api::PrepareInput.new("greffe", fiscal_year_id: S.fiscal_year_id))
        {form, result.error_keys}.should eq({form, [key]})
        Api.schedule(S.admin, S.fiscal_year_id).map(&.kind).should_not contain("greffe")
      end
      I18n.with_locale("fr") { I18n.t("teledec.errors.greffe.legal_form", {"form" => "SCI"}).should contain("« SCI »") }
      I18n.with_locale("nl") { I18n.t("teledec.errors.greffe.legal_form", {"form" => "SCI"}).should contain("SCI") }
      S.legal_form("SAS")
      Books.sale(Books.card("CUSTOMER", "Atelier Morel").code, "1000")
      Api.schedule(S.admin, S.fiscal_year_id).map(&.kind).should contain("greffe")
      prepared = S.prepare("greffe", fiscal_year_id: S.fiscal_year_id)
      # Liasse de l'exercice pas encore transmise : avertissement.
      prepared.warnings.map(&.key).should contain("teledec.controls.greffe_liasse")
      prepared.ready?.should be_true
    end

    it "refuse aussi à l'envoi une forme qui ne dépose pas ses comptes, sans rien envoyer" do
      exchange = GreffeExchange.new
      error_of { transport(exchange).submit(credentials, greffe_submission(greffe_payload("SCI"))) }.key
        .should eq("teledec.errors.transport.greffe_legal_form")
      exchange.requests.should be_empty
    end
  end

  describe "amorce (POST /service/nouvelle-declaration)" do
    it "demande le droit nouvelle-declaration au jeton, stage/ ou prod/" do
      exchange = GreffeExchange.new
      transport(exchange).check(credentials)
      scopes = URI::Params.parse(exchange.last("/oauth2/token").body)["scope"].split(' ')
      scopes.should contain("stage/nouvelle-declaration")
      scopes.should contain("stage/liasse")
      Teledec::HttpTransport::SCOPES.should contain("nouvelle-declaration")
    end

    it "envoie formulaire greffe, compte, identité et exercice, et rend l'adresse de redirection (JSON ou texte)" do
      [%({"url": "https://stage.teledec.fr/service/autologin/abc?redirect=greffe"}),
       %({"status": "ok", "urlRedirection": "https://stage.teledec.fr/service/autologin/abc?redirect=greffe"}),
       "https://stage.teledec.fr/service/autologin/abc?redirect=greffe\n"].each do |body|
        exchange = GreffeExchange.new.script("/service/nouvelle-declaration", 200, body)
        submitted = transport(exchange).submit(credentials, greffe_submission)
        submitted.url.should eq("https://stage.teledec.fr/service/autologin/abc?redirect=greffe")
        submitted.remote_id.should eq("greffe:732829320:2026-06-30")
        submitted.remote_status.should eq("notcompleted")
        request = exchange.last("/service/nouvelle-declaration")
        request.method.should eq("POST")
        request.url.should eq("https://stage.teledec.fr/service/nouvelle-declaration")
        request.headers["Content-Type"].should eq("application/json")
        document = JSON.parse(request.body)
        document["formulaire"].as_s.should eq("greffe")
        document["auth"]["email"].as_s.should eq("teledec-732829320@partiduo.test")
        document["auth"]["timestamp"].as_s.should eq("2026-10-01T10:00:00")
        document["auth"]["url"].as_s.should eq("https://dossier.exemple.fr/hooks/TELEDEC/callback")
        document["identity"]["siret"].as_s.should eq("73282932000074")
        document["identity"]["legalForm"].as_s.should eq("SAS")
        {document["identity"]["yearEndMonth"].as_i, document["identity"]["yearEndDay"].as_i}.should eq({6, 30})
        {document["period"]["begin"].as_s, document["period"]["end"].as_s}.should eq({"2025-07-01", "2026-06-30"})
        document["period"]["reference"].as_s.should eq("partiduo-7-1-abc")
        document["period"]["millesime"]?.should be_nil
      end
    end

    it "signale un refus avec son motif, une réponse sans adresse, et un droit absent du jeton" do
      exchange = GreffeExchange.new.script("/service/nouvelle-declaration", 200, %({"message": "Liasse absente"}))
      refused = error_of { transport(exchange).submit(credentials, greffe_submission) }
      refused.key.should eq("teledec.errors.transport.refused")
      refused.params["reason"].should eq("Liasse absente")
      exchange = GreffeExchange.new.script("/service/nouvelle-declaration", 200, %({"status": "ok"}))
      error_of { transport(exchange).submit(credentials, greffe_submission) }.key.should eq("teledec.errors.transport.no_link")
      # Route refusée au jeton (403, puis 403 après un nouveau jeton).
      exchange = GreffeExchange.new.script("/service/nouvelle-declaration", 403, "Forbidden")
      denied = error_of { transport(exchange).submit(credentials, greffe_submission) }
      denied.key.should eq("teledec.errors.transport.scope")
      denied.params["scope"].should eq("nouvelle-declaration")
    end

    it "prend un jeton sans le droit facultatif si le service des jetons le refuse ; seul le greffe est alors refusé" do
      exchange = GreffeExchange.new.reset("/oauth2/token")
        .script("/oauth2/token", 400, %({"error": "invalid_scope"}))
        .script("/oauth2/token", 200, %({"access_token": "jeton-2", "expires_in": 3600}))
      adapter = transport(exchange)
      adapter.check(credentials)
      tokens = exchange.requests.select(&.path.==("/oauth2/token"))
      tokens.size.should eq(2)
      URI::Params.parse(tokens.last.body)["scope"].split(' ').should_not contain("stage/nouvelle-declaration")
      error = error_of { adapter.submit(credentials, greffe_submission) }
      error.key.should eq("teledec.errors.transport.scope")
      exchange.requests.map(&.path).should_not contain("/service/nouvelle-declaration")
      I18n.t(error.key, error.params).should contain("nouvelle-declaration")
      # Un autre refus du service des jetons reste un refus des identifiants.
      exchange = GreffeExchange.new.reset("/oauth2/token").script("/oauth2/token", 400, %({"error": "invalid_client"}))
      error_of { transport(exchange).check(credentials) }.key.should eq("teledec.errors.transport.credentials")
      # Droits annoncés par le service des jetons : ils font foi.
      exchange = GreffeExchange.new.reset("/oauth2/token")
        .script("/oauth2/token", 200, %({"access_token": "j", "expires_in": 3600, "scope": "stage/liasse stage/marque-blanche"}))
      error_of { transport(exchange).submit(credentials, greffe_submission) }.key.should eq("teledec.errors.transport.scope")
    end
  end

  describe "PDF du dépôt (GET /service/declarationPdf/{token}/teledec-liasse-fiscale.pdf)" do
    it "tire le jeton de lienPdf, et rien d'une adresse sans jeton" do
      Formats.pdf_token("https://www.teledec.fr/service/declarationPdf/eyJhbGciOi.abc_DEF-1/teledec-liasse-fiscale.pdf")
        .should eq("eyJhbGciOi.abc_DEF-1")
      Formats.pdf_token("http://www.teledec.fr/service/declarationPdf/xxxxxxxxxx/teledec-liasse-fiscale.pdf").should eq("xxxxxxxxxx")
      Formats.pdf_token("eyJhbGciOiJIUzI1NiJ9").should eq("eyJhbGciOiJIUzI1NiJ9")
      Formats.pdf_token("").should be_nil
      Formats.pdf_token("https://www.teledec.fr/autre/chose").should be_nil
      Formats.pdf_path("abc.DEF_123").should eq("/service/declarationPdf/abc.DEF_123/teledec-liasse-fiscale.pdf")
    end

    it "relève le PDF d'un dépôt finalisé sur la route de l'environnement, jamais à l'adresse reçue" do
      link = "https://ailleurs.example/service/declarationPdf/jeton-du-pdf-0001/teledec-liasse-fiscale.pdf"
      exchange = GreffeExchange.new
        .script("/service/declaration-status", 200, %({"status": "Sent", "lienPdf": "#{link}"}))
        .script("/service/declarationPdf/jeton-du-pdf-0001/teledec-liasse-fiscale.pdf", 200, "%PDF-1.7 signé", "application/pdf")
      status = transport(exchange).status(credentials, "greffe:732829320:2026-06-30")
      {status.state, status.remote_status}.should eq({"pending", "sent"})
      document = status.document || raise "PDF absent"
      document.filename.should eq("depot-greffe-732829320-2026-06-30.pdf")
      document.content_type.should eq("application/pdf")
      String.new(document.content).should eq("%PDF-1.7 signé")
      exchange.last("/service/declaration-status").query_params["formulaire"].should eq("greffe")
      fetched = exchange.last("/service/declarationPdf/jeton-du-pdf-0001/teledec-liasse-fiscale.pdf")
      fetched.url.should start_with("https://stage.teledec.fr/")
      fetched.headers["Accept"].should eq("application/pdf")
      exchange.requests.none?(&.url.includes?("ailleurs.example")).should be_true
    end

    it "ne relève rien avant la finalisation, ni pour une autre déclaration ; refuse un corps qui n'est pas un PDF" do
      link = "https://stage.teledec.fr/service/declarationPdf/jeton-du-pdf-0002/teledec-liasse-fiscale.pdf"
      exchange = GreffeExchange.new.script("/service/declaration-status", 200, %({"status": "NotCompleted", "lienPdf": "#{link}"}))
      transport(exchange).status(credentials, "greffe:732829320:2026-06-30").document.should be_nil
      exchange.reset("/service/declaration-status").script("/service/declaration-status", 200, %({"status": "Sent", "lienPdf": "#{link}"}))
      transport(exchange).status(credentials, "liasse:732829320:2026-06-30").document.should be_nil
      exchange.requests.map(&.path).none?(&.starts_with?("/service/declarationPdf/")).should be_true
      exchange.script("/service/declarationPdf/jeton-du-pdf-0002/teledec-liasse-fiscale.pdf", 200, "<html>expiré</html>", "text/html")
      error = error_of { transport(exchange).status(credentials, "greffe:732829320:2026-06-30") }
      error.key.should eq("teledec.errors.transport.document")
      exchange.reset("/service/declarationPdf/jeton-du-pdf-0002/teledec-liasse-fiscale.pdf")
        .script("/service/declarationPdf/jeton-du-pdf-0002/teledec-liasse-fiscale.pdf", 404, %({"message": "lien expiré"}))
      error = error_of { transport(exchange).status(credentials, "greffe:732829320:2026-06-30") }
      {error.key, error.params["reason"]}.should eq({"teledec.errors.transport.document", "lien expiré"})
    end
  end

  describe "parcours complet (TELEDEC simulé)" do
    it "amorce, ouvre l'adresse, conserve le PDF signé dès la finalisation (suivi), puis l'accusé" do
      filing = transmitted_greffe
      filing.status.should eq("transmitted")
      filing.remote_url.should start_with("https://stage.teledec.fr/service/autologin/")
      Api.refresh(S.admin, filing.id).value!.document_attachment_id.should be_nil # pas encore finalisé
      S.teledec.finalize_greffe(GREFFE_ID)
      finalized = Api.refresh(S.admin, filing.id).value!
      {finalized.status, finalized.remote_status}.should eq({"transmitted", "sent"})
      document = Api.document_file(S.admin, filing.id) || raise "PDF du dépôt absent"
      document.filename.should eq("depot-greffe-732829320-2026-12-31.pdf")
      String.new(document.content).should start_with("%PDF-1.7")
      Api.receipt_file(S.admin, filing.id).should be_nil
      S.teledec.acknowledge(GREFFE_ID)
      done = Api.refresh(S.admin, filing.id).value!
      done.status.should eq("acknowledged")
      done.document_attachment_id.should eq(finalized.document_attachment_id) # conservé une fois
      Api.receipt_file(S.admin, filing.id).should_not be_nil
      events = Api.events(S.admin, filing.id)
      events.map(&.status).should eq(%w[prepared transmitted transmitted acknowledged])
      events[2].detail.should contain("depot-greffe-732829320-2026-12-31.pdf")
    end

    it "conserve le PDF signé à réception du rappel de finalisation, une seule fois" do
      filing = transmitted_greffe
      S.teledec.finalize_greffe(GREFFE_ID)
      body = S.teledec.callback_body(GREFFE_ID)
      Api.callback(S.callback_authorization, body).should eq("ok")
      sent = Api.filing(S.admin, filing.id)
      {sent.status, sent.remote_status}.should eq({"transmitted", "sent"})
      first = sent.document_attachment_id || raise "PDF du dépôt absent"
      Api.callback(S.callback_authorization, body).should eq("ok")
      S.teledec.acknowledge(GREFFE_ID)
      Api.callback(S.callback_authorization, S.teledec.callback_body(GREFFE_ID)).should eq("ok")
      done = Api.filing(S.admin, filing.id)
      done.status.should eq("acknowledged")
      done.document_attachment_id.should eq(first)
      pdf_fetches = S.teledec.requests.count(&.path.starts_with?("/service/declarationPdf/"))
      pdf_fetches.should eq(1)
    end

    it "garde le dépôt transmis si le PDF ne peut être relevé au rappel, et le reprend au suivi" do
      filing = transmitted_greffe
      S.teledec.acknowledge(GREFFE_ID)
      saved = S.teledec.server.documents.dup
      S.teledec.server.documents.clear
      Api.callback(S.callback_authorization, S.teledec.callback_body(GREFFE_ID)).should eq("ok")
      pending = Api.filing(S.admin, filing.id)
      {pending.status, pending.last_error, pending.document_attachment_id}
        .should eq({"transmitted", "teledec.errors.transport.document", nil})
      Api.refresh(S.admin, filing.id).error_keys.should eq(["teledec.errors.transport.document"])
      Api.filing(S.admin, filing.id).status.should eq("transmitted")
      S.teledec.server.documents.merge!(saved)
      done = Api.refresh(S.admin, filing.id).value!
      done.status.should eq("acknowledged")
      done.document_attachment_id.should_not be_nil
      done.last_error.should eq("")
    end

    it "refuse l'amorce tant que le droit nouvelle-declaration n'est pas accordé, sans gêner les autres dépôts" do
      Teledec::Transports.current = Teledec::SimulatedTeledec.new.tap(&.refused_scopes.add("nouvelle-declaration"))
      S.books(greffe: true)
      Books.sale(Books.card("CUSTOMER", "Atelier Morel").code, "1000")
      S.connect
      Api.transmit(S.admin, S.liasse.id).value!.status.should eq("transmitted")
      filing = S.prepare("greffe", fiscal_year_id: S.fiscal_year_id)
      Api.transmit(S.admin, filing.id).error_keys.should eq(["teledec.errors.transport.scope"])
      Api.filing(S.admin, filing.id).status.should eq("prepared")
      S.teledec.requests.map(&.path).should_not contain("/service/nouvelle-declaration")
    end

    it "montre le bouton qui ouvre l'adresse de TELEDEC dans un nouvel onglet, puis le PDF du dépôt" do
      filing = transmitted_greffe
      browser = PartiduoUi::Accounts.signed_in
      url = "/ext/TELEDEC/filings/#{filing.id}"
      html = browser.get(url).html
      html.should match(/href="https:\/\/stage\.teledec\.fr\/service\/autologin\/[^"]+" target="_blank" rel="noopener noreferrer" data-teledec-open/)
      html.should contain("Finaliser le dépôt chez TELEDEC")
      html.should_not contain("data-teledec-document")
      S.teledec.finalize_greffe(GREFFE_ID)
      browser.post("#{url}/refresh").status.should eq(302)
      html = browser.get(url).html
      html.should contain(%(href="#{url}/document" data-teledec-document))
      html.should contain("PDF du dépôt au greffe")
      response = browser.get("#{url}/document")
      response.status.should eq(200)
      response.content_type.should start_with("application/pdf")
      String.new(response.content.to_slice).should start_with("%PDF-1.7")
    end
  end
end
