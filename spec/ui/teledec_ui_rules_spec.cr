# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Teledec::SpecSupport
private alias Api = Teledec::Api
private alias Books = PartiduoUi::Books

# Dossier prêt (une vente) et navigateur de l'utilisateur au profil
# restreint `permissions`.
private def restricted(permissions : Array(String)) : PartiduoUi::Browser
  S.books
  Books.sale(Books.card("CUSTOMER", "Atelier Morel").code, "1000")
  profile = PartiduoUi::Accounts.profile("Lecture TELEDEC", permissions)
  PartiduoUi::Accounts.create("bob@example.com", profile: nil, profile_id: profile)
  PartiduoUi::Accounts.signed_in("bob@example.com")
end

describe "Écrans TELEDEC : droits, rejets et cas limites" do
  it "montre un dépôt en lecture seule à qui n'a que teledec.return.read, et refuse ses commandes" do
    browser = restricted([Api::READ, "accounting.report.read"])
    S.connect
    filing = S.liasse
    url = "/ext/TELEDEC/filings/#{filing.id}"
    html = browser.get(url).html
    html.should contain(%(data-teledec-filing="prepared"))
    html.should_not contain("data-teledec-transmit")
    html.should_not contain("data-teledec-check")
    html.should_not contain("data-teledec-outcome")
    browser.post("#{url}/transmit").status.should eq(403)
    browser.post("#{url}/check").status.should eq(403)
    browser.post("#{url}/outcome", {"status" => "transmitted"}).status.should eq(403)
    browser.post("/ext/TELEDEC/prepare", {"kind" => "liasse", "fiscal_year_id" => S.fiscal_year_id.to_s}).status.should eq(403)
    browser.get("/ext/TELEDEC/balance/#{S.fiscal_year_id}").status.should eq(403)
    browser.get("/ext/TELEDEC/settings").status.should eq(403)
    browser.post("/ext/TELEDEC/settings/credentials/clear").status.should eq(403)
    Api.filing(S::SYSTEM, filing.id).status.should eq("prepared")
    Api.settings(S::SYSTEM).key_stored.should be_true
    browser.get("#{url}/export").status.should eq(200)
  end

  it "refuse tout l'écran sans teledec.return.read" do
    browser = restricted(["accounting.report.read"])
    browser.get("/ext/TELEDEC/").status.should eq(403)
    browser.get("/ext/TELEDEC/settings").status.should eq(403)
  end

  it "affiche le motif d'un rejet et prépare de nouveau le dépôt" do
    S.books
    Books.sale(Books.card("CUSTOMER", "Atelier Morel").code, "1000")
    browser = PartiduoUi::Accounts.signed_in
    S.connect
    filing = S.liasse
    Api.transmit(S.admin, filing.id).value!
    S.teledec.reject("TD-000001", "SIREN inconnu de la DGFiP")
    url = "/ext/TELEDEC/filings/#{filing.id}"
    browser.post("#{url}/refresh").status.should eq(302)
    html = browser.get(url).html
    html.should contain(%(data-teledec-filing="rejected"))
    html.should contain("SIREN inconnu de la DGFiP")
    html.should contain("data-teledec-prepare-again")
    html.should_not contain("data-teledec-outcome")
    response = browser.post("/ext/TELEDEC/prepare", {"kind" => "liasse", "fiscal_year_id" => S.fiscal_year_id.to_s})
    response.headers["Location"].should eq(url)
    browser.get(url).html.should contain(%(data-teledec-filing="prepared"))
  end

  it "rend compte d'une préparation refusée et d'un dépôt inconnu" do
    S.books
    browser = PartiduoUi::Accounts.signed_in
    response = browser.post("/ext/TELEDEC/prepare", {"kind" => "greffe", "fiscal_year_id" => S.fiscal_year_id.to_s})
    response.status.should eq(302)
    response.headers["Location"].should eq("/ext/TELEDEC/?fy=#{S.fiscal_year_id}")
    browser.post("/ext/TELEDEC/prepare", {"kind" => "bilan"}).headers["Location"].should eq("/ext/TELEDEC/")
    Api.filings(S.admin).should be_empty
    browser.get("/ext/TELEDEC/filings/987654").status.should eq(404)
    browser.post("/ext/TELEDEC/filings/987654/transmit").status.should eq(404)
    browser.get("/ext/TELEDEC/balance/987654").status.should eq(404)
  end

  it "efface les identifiants de l'API et répond 404 sur les paramètres d'une extension inactive" do
    S.books
    browser = PartiduoUi::Accounts.signed_in
    S.connect
    browser.post("/ext/TELEDEC/settings/credentials/clear").status.should eq(302)
    Api.settings(S::SYSTEM).key_stored.should be_false
    Partiduo::Api::Modules.deactivate(S::SYSTEM, Teledec::CODE).value!
    browser.get("/ext/TELEDEC/settings").status.should eq(404)
    browser.get("/ext/TELEDEC/filings/1").status.should eq(404)
  end
end
