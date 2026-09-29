# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Teledec::SpecSupport
private alias Books = PartiduoUi::Books

private def signed_in : PartiduoUi::Browser
  S.books
  Books.sale(Books.card("CUSTOMER", "Atelier Morel").code, "1000")
  PartiduoUi::Accounts.signed_in
end

describe "Écran Télédéclarations sous /ext/TELEDEC/ (ADR-005 D4)" do
  it "est montée sous le code de l'extension, avec la permission de lecture" do
    Marten.routes.reverse("teledec:index").should eq("/ext/TELEDEC/")
    mount = PartiduoUi::Extensions["TELEDEC"]? || raise("interface non montée")
    mount.permission.should eq(Teledec::Api::READ)
  end

  it "n'existe pas tant que l'extension est inactive (404)" do
    PartiduoUi::Reference.provision("fr")
    PartiduoUi::Reference.fiscal_year(2026)
    PartiduoUi::Accounts.create
    PartiduoUi::Accounts.signed_in.get("/ext/TELEDEC/").status.should eq(404)
  end

  it "liste les échéances, prépare, contrôle et note un dépôt fait hors de Partiduo" do
    browser = signed_in
    Teledec::Transports.current = nil
    html = browser.get("/ext/TELEDEC/?fy=#{S.fiscal_year_id}").html
    html.should contain("<h1>Télédéclarations")
    html.should contain(%(data-teledec-transport="unavailable"))
    html.should contain(%(data-teledec-deadline="liasse:#{S.fiscal_year_id}"))
    html.should contain(%(data-teledec-deadline="das2:2026"))
    html.should contain("Acompte d'IS (2571)")
    html.should contain("Clôturez d'abord la déclaration de TVA")
    html.should contain("/ext/TELEDEC/balance/#{S.fiscal_year_id}")
    response = browser.post("/ext/TELEDEC/prepare", {"kind" => "liasse", "fiscal_year_id" => S.fiscal_year_id.to_s})
    response.status.should eq(302)
    location = response.headers["Location"]
    location.should match(%r{/ext/TELEDEC/filings/\d+})
    page = browser.get(location).html
    page.should contain("Liasse fiscale")
    page.should contain(%(data-teledec-filing="prepared"))
    page.should contain("2065, 2033")
    page.should contain(%(data-teledec-control="teledec.controls.fiscal_year_open"))
    page.should contain("Atelier Brunet SARL")
    page.should contain(%(data-teledec-outcome))
    browser.post("#{location}/check").status.should eq(302)
    browser.post("#{location}/transmit").status.should eq(302)
    browser.get(location).html.should contain("La transmission directe à TELEDEC est désactivée sur cette instance")
    browser.post("#{location}/outcome", {"status" => "transmitted", "reference" => "WEB-7"}).status.should eq(302)
    page = browser.get(location).html
    page.should contain(%(data-teledec-filing="transmitted"))
    page.should contain("WEB-7")
    index = browser.get("/ext/TELEDEC/?fy=#{S.fiscal_year_id}").html
    index.should contain(%(data-teledec-status="transmitted"))
    csv = browser.get("/ext/TELEDEC/balance/#{S.fiscal_year_id}")
    csv.headers["Content-Disposition"].should contain("732829320-balance-20261231.csv")
    browser.get("#{location}/export").content.should contain(%("schema":"partiduo-teledec/1"))
  end

  it "montre l'identité d'un bénéficiaire personne physique de la DAS2" do
    browser = signed_in
    code = S.supplier("Cabinet Durand", supplier_nature: "individual", last_name: "DURAND", first_names: "Paul",
      birth_date: Time.utc(1971, 4, 2))
    S.fees(code, "1500")
    response = browser.post("/ext/TELEDEC/prepare", {"kind" => "das2", "year" => "2026"})
    response.status.should eq(302)
    page = browser.get(response.headers["Location"]).html
    page.should contain(%(data-teledec-person>Personne physique : DURAND Paul, né(e) le 02/04/1971))
  end

  it "transmet par le transport et affiche l'accusé" do
    browser = signed_in
    S.connect
    filing = S.liasse
    url = "/ext/TELEDEC/filings/#{filing.id}"
    browser.get(url).html.should contain(%(data-teledec-transmit))
    browser.post("#{url}/transmit").status.should eq(302)
    browser.get(url).html.should contain(S::LIASSE_ID)
    S.teledec.acknowledge(S::LIASSE_ID)
    browser.post("#{url}/refresh").status.should eq(302)
    html = browser.get(url).html
    html.should contain(%(data-teledec-filing="acknowledged"))
    html.should contain(%(data-teledec-receipt))
    browser.get("#{url}/receipt").content.should start_with("%PDF-1.4")
  end

  it "enregistre les paramètres et les identifiants sans jamais réafficher la clé" do
    browser = signed_in
    html = browser.get("/ext/TELEDEC/settings").html
    html.should contain("Paramètres de TELEDEC")
    html.should contain(%(data-teledec-env="sandbox"))
    browser.post("/ext/TELEDEC/settings", {"tax_system" => "is_rn", "vat_system" => "ca12", "greffe" => "1",
                                           "das2_threshold" => "1200", "das2_accounts" => "6226=fees\n6222=commissions"}).status.should eq(302)
    Teledec::Api.settings(S::SYSTEM).tax_system.should eq("is_rn")
    refused = browser.post("/ext/TELEDEC/settings", {"tax_system" => "is_rn", "vat_system" => "ca12", "das2_accounts" => "abc=fees"})
    refused.status.should eq(422)
    refused.html.should contain("Compte de la DAS2 invalide : abc.")
    bad = browser.post("/ext/TELEDEC/settings/credentials", {"login" => Teledec::SimulatedTeledec::LOGIN, "api_key" => "faux", "env" => "sandbox"})
    bad.status.should eq(422)
    bad.html.should contain("TELEDEC refuse ces identifiants.")
    ok = browser.post("/ext/TELEDEC/settings/credentials", {"login" => Teledec::SimulatedTeledec::LOGIN,
                                                            "api_key" => Teledec::SimulatedTeledec::API_KEY, "env" => "sandbox"})
    ok.status.should eq(302)
    html = browser.get("/ext/TELEDEC/settings").html
    html.should contain("Enregistrée — laissez vide pour la garder")
    html.should_not contain(Teledec::SimulatedTeledec::API_KEY)
  end
end
