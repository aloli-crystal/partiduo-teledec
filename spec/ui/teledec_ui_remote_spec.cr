# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Teledec::SpecSupport
private alias Books = PartiduoUi::Books
private alias Acc = Partiduo::Api::Accounting
private alias Sim = Teledec::SimulatedTeledec

# Requête arrivée par un autre hôte, en http, sur un autre port : l'adresse
# des rappels n'en dépend pas (domaine de la société, en https).
private HOST   = {"Host" => "127.0.0.1:8000"}
private PUBLIC = "https://demo.partiduo.localhost"

private def signed_in : PartiduoUi::Browser
  S.books
  Books.sale(Books.card("CUSTOMER", "Atelier Morel").code, "1000")
  PartiduoUi::Accounts.signed_in
end

describe "Écrans de l'adaptateur réel de TELEDEC" do
  it "enregistre l'email de contact et le SIRET, montre le compte de l'entreprise et l'adresse publique des rappels" do
    browser = signed_in
    html = browser.get("/ext/TELEDEC/settings").html
    html.should contain(%(name="email"))
    html.should contain(%(name="siret"))
    html.should_not contain("renew_callback_token")
    refused = browser.post("/ext/TELEDEC/settings/credentials", {"login" => Sim::LOGIN, "api_key" => Sim::API_KEY,
                                                                 "env" => "sandbox", "email" => "pas-un-email", "siret" => "123"})
    refused.status.should eq(422)
    refused.html.should match(/id="pd-teledec-email" name="email" value="[^"]*" aria-invalid="true"/)
    refused.html.should match(/id="pd-teledec-siret" name="siret" value="[^"]*" aria-invalid="true"/)
    refused.html.should contain("SIRET à 14 chiffres attendu.")
    browser.post("/ext/TELEDEC/settings/credentials", {"login" => Sim::LOGIN, "api_key" => Sim::API_KEY, "env" => "sandbox",
                                                       "email" => Sim::EMAIL, "siret" => "732 829 320 00074"}).status.should eq(302)
    html = browser.get("/ext/TELEDEC/settings", HOST).html
    html.should contain(%(value="#{Sim::EMAIL}"))
    html.should contain(%(value="73282932000074"))
    html.should contain("data-teledec-callback")
    html.should contain(%(value="#{PUBLIC}/hooks/TELEDEC/callback"))
    html.should_not contain("127.0.0.1:8000/hooks")
    html.should contain(Sim::ACCOUNT)
    html.should contain("data-teledec-callback-ready")
    # Domaine du partenaire non réglé : signalé.
    Teledec::Transports.current = Sim.new(user_domain: nil)
    html = browser.get("/ext/TELEDEC/settings").html
    html.should contain("data-teledec-no-domain")
    html.should contain("PARTIDUO_TELEDEC_USER_DOMAIN")
  end

  it "signale l'absence d'adresse publique en https au lieu d'afficher une adresse de rappel" do
    browser = signed_in
    S.connect
    Marten::DB::Connection.default.open(&.exec("UPDATE core_settings SET domain = ''"))
    previous = {ENV["PARTIDUO_HOST"]?, ENV["MARTEN_ALLOWED_HOSTS"]?}
    begin
      ENV.delete("PARTIDUO_HOST")
      ENV.delete("MARTEN_ALLOWED_HOSTS")
      html = browser.get("/ext/TELEDEC/settings", HOST).html
      html.should_not contain("data-teledec-callback>")
      html.should contain("data-teledec-callback-no-host")
    ensure
      previous[0] ? (ENV["PARTIDUO_HOST"] = previous[0]) : ENV.delete("PARTIDUO_HOST")
      previous[1] ? (ENV["MARTEN_ALLOWED_HOSTS"] = previous[1]) : ENV.delete("MARTEN_ALLOWED_HOSTS")
    end
  end

  it "donne à TELEDEC l'adresse des rappels de l'instance, puis montre l'état chez TELEDEC et le lien de la déclaration" do
    browser = signed_in
    S.connect
    created = Acc.create_vat_return(S::SYSTEM, Acc::VatReturnInput.new(form: "fr_ca3", year: 2026, periodicity: "month", number: 3)).value!
    closed = Acc.close_vat_return(S::SYSTEM, (created.id || raise("déclaration sans identifiant")), nil).value!
    filing = S.prepare("vat_ca3", vat_return_id: closed.id)
    url = "/ext/TELEDEC/filings/#{filing.id}"
    browser.get(url).html.should_not contain("data-teledec-open")
    browser.post("#{url}/transmit", headers: HOST).status.should eq(302)
    document = JSON.parse(S.teledec.requests.reverse.find!(&.path.==("/service/declaration-marque-blanche")).body)
    document["auth"]["url"].as_s.should eq("#{PUBLIC}/hooks/TELEDEC/callback")
    html = browser.get(url).html
    html.should contain(%(data-teledec-remote-status="readytobesent"))
    html.should contain(%(data-teledec-open))
    html.should contain(%(href="https://stage.teledec.fr/service/declaration/))
    html.should contain(%(rel="noopener noreferrer"))
  end

  it "montre une DAS2 que le suivi ne trouve pas encore comme créée chez TELEDEC, à finaliser, sans erreur, jusqu'à l'ouverture de son lien" do
    browser = signed_in
    S.connect
    # Comme sur le stage : suivi en 404 juste après le dépôt (D-TDC11-002),
    # DAS2 listée `Created` sous la liasse de son année (D-TDC12-002).
    S.teledec.hidden_until_opened << "DAS2"
    S.fees(S.supplier("Cabinet Durand"), "1500")
    filing = S.prepare("das2", year: 2026)
    url = "/ext/TELEDEC/filings/#{filing.id}"
    browser.post("#{url}/transmit").status.should eq(302)
    browser.post("#{url}/refresh").status.should eq(302)
    view = Teledec::Api.filing(S.admin, filing.id)
    {view.status, view.remote_status, view.last_error}.should eq({"transmitted", "created", ""})
    html = browser.get(url).html
    html.should contain(%(data-teledec-remote-status="created"))
    html.should contain("Créée chez TELEDEC, à finaliser")
    html.should contain("data-teledec-awaiting")
    html.should contain("data-teledec-open")
    html.should contain("data-teledec-refresh")
    # Lien ouvert : le suivi trouve la déclaration.
    S.teledec.open_link(view.remote_id)
    Teledec::Api.refresh(S.admin, filing.id).value!.remote_status.should eq("readytobesent")
    html = browser.get(url).html
    html.should contain(%(data-teledec-remote-status="readytobesent"))
    html.should_not contain("data-teledec-awaiting")
  end

  it "montre une liasse que ni le suivi ni la liste ne trouvent encore comme en attente de finalisation chez TELEDEC" do
    browser = signed_in
    S.connect
    # Comme sur le stage : la liasse par l'API Balance n'est ni suivie ni
    # listée avant l'ouverture de son lien (D-TDC12-002).
    S.teledec.hidden_until_opened << "liasse"
    filing = S.liasse
    url = "/ext/TELEDEC/filings/#{filing.id}"
    browser.post("#{url}/transmit").status.should eq(302)
    browser.post("#{url}/refresh").status.should eq(302)
    view = Teledec::Api.filing(S.admin, filing.id)
    {view.status, view.remote_status, view.last_error}.should eq({"transmitted", "notfound", ""})
    html = browser.get(url).html
    html.should contain(%(data-teledec-remote-status="notfound"))
    html.should contain("En attente de finalisation chez TELEDEC")
    html.should contain("data-teledec-awaiting")
  end

  it "n'ouvre pas une adresse de TELEDEC qui n'est pas en https" do
    browser = signed_in
    S.connect
    filing = S.liasse
    Teledec::Api.transmit(S.admin, filing.id).value!
    Marten::DB::Connection.default.open(&.exec("UPDATE teledec_filing SET remote_url = 'javascript:alert(1)', remote_status = 'étrange' WHERE id = $1", filing.id))
    html = browser.get("/ext/TELEDEC/filings/#{filing.id}").html
    html.should_not contain("javascript:alert")
    html.should_not contain("data-teledec-open")
    html.should contain(%(data-teledec-remote-status="étrange"))
  end

  it "refuse un rappel au mot de passe faux ou à l'en-tête Basic illisible, en demandant l'authentification" do
    signed_in
    S.connect
    client = Marten::Spec::Client.new
    ["Basic %%%", "Basic #{Base64.strict_encode("teledec:faux")}", "Bearer faux"].each do |header|
      response = client.post("/hooks/TELEDEC/callback", content_type: "application/json", data: "{}",
        headers: {"Authorization" => header})
      response.status.should eq(401)
      response.headers["WWW-Authenticate"].should contain("Basic")
    end
    client.post("/hooks/TELEDEC/callback", query_params: {"token" => ENV["PARTIDUO_TELEDEC_CALLBACK_PASSWORD"]},
      content_type: "application/json", data: "{}").status.should eq(401)
    # Corps annoncé trop gros : 413, sans le lire (requête construite à la
    # main : le client des specs recalcule `Content-Length`).
    headers = ::HTTP::Headers{"Host" => "127.0.0.1", "Content-Type" => "application/json",
                              "Content-Length" => (Teledec::Callbacks::MAX_BYTES + 1).to_s}
    headers["Authorization"] = S.callback_authorization
    raw = ::HTTP::Request.new("POST", "/hooks/TELEDEC/callback", headers, IO::Memory.new("{}"))
    Teledec::Ui::CallbackHandler.new(Marten::HTTP::Request.new(raw)).dispatch.status.should eq(413)
    # Mot de passe juste, rappel sans dépôt correspondant : 200 (rien à faire).
    client.post("/hooks/TELEDEC/callback", content_type: "application/json",
      data: %({"reference": "inconnue", "status": "OK"}), headers: {"Authorization" => S.callback_authorization}).status.should eq(200)
  end
end
