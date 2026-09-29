# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Teledec::SpecSupport

# Écran d'un libéral sans Comptabilité (DECISIONS D-TDC2-004) : la liasse
# 2035 seule, ni TVA, ni DAS2, ni export de la balance.
describe "Écran Télédéclarations d'un libéral sans Comptabilité (D-TDC2)" do
  it "ne propose que la 2035 et la prépare depuis le module liberal" do
    S.liberal_books
    S.liberal_line("receipt", "2026-03-01", "42000", "RECEIPTS")
    browser = PartiduoUi::Accounts.signed_in
    Teledec::Transports.current = nil
    html = browser.get("/ext/TELEDEC/?fy=#{S.fiscal_year_id}").html
    html.should contain(%(data-teledec-liberal-only))
    html.should contain("seule la liasse 2035 est proposée")
    html.should contain(%(data-teledec-deadline="liasse:#{S.fiscal_year_id}"))
    html.should_not contain(%(data-teledec-deadline="das2:2026))
    html.should_not contain("Acompte d'IS")
    html.should_not contain("/ext/TELEDEC/balance/")
    html.should_not contain("data-teledec-unconfigured")
    html.should contain("BNC, déclaration contrôlée (2035)")
    html.should contain("Formule API Balance sans balance")

    response = browser.post("/ext/TELEDEC/prepare", {"kind" => "liasse", "fiscal_year_id" => S.fiscal_year_id.to_s})
    response.status.should eq(302)
    page = browser.get(response.headers["Location"]).html
    page.should contain(%(data-teledec-filing="prepared"))
    page.should contain("2035 du module Profession libérale (sans balance)")
    page.should contain(%(data-teledec-boxes))
    page.should_not contain("/ext/TELEDEC/balance/")

    refused = browser.post("/ext/TELEDEC/prepare", {"kind" => "das2", "year" => "2026"})
    refused.status.should eq(302)
    browser.get(refused.headers["Location"]).html.should contain("nécessite le module Comptabilité")
    browser.get("/ext/TELEDEC/balance/#{S.fiscal_year_id}").status.should eq(404)
  end

  it "règle le seul régime BNC, sans TVA, greffe ni DAS2" do
    S.liberal_books
    browser = PartiduoUi::Accounts.signed_in
    html = browser.get("/ext/TELEDEC/settings").html
    html.should contain(%(<option value="bnc" selected>))
    html.should_not contain(%(value="is_rsi"))
    html.should_not contain(%(name="vat_system"))
    html.should_not contain(%(name="das2_accounts"))
    html.should contain(%(data-teledec-liberal-only))
    browser.post("/ext/TELEDEC/settings", {"tax_system" => "bnc"}).status.should eq(302)
    Teledec::Settings.current!.tax_system.should eq("bnc")
    browser.post("/ext/TELEDEC/settings", {"tax_system" => "is_rsi"}).html.should contain("nécessite le module Comptabilité")
  end
end
