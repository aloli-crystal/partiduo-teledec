# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Teledec::SpecSupport
private alias Api = Teledec::Api
private alias Acc = Partiduo::Api::Accounting
private alias Books = PartiduoUi::Books

private def sale(amount : String = "1000") : Nil
  code = Partiduo::Api::Cards.cards(S::SYSTEM, Partiduo::Api::Cards::CardQuery.new(kind: "customer")).first?.try(&.code) ||
         Books.card("CUSTOMER", "Atelier Morel").code
  Books.sale(code, amount)
  nil
end

describe "Liasse fiscale (formule API Balance, ADR-007 D4)" do
  it "prépare la liasse de l'exercice : formulaires du régime, identité, balance équilibrée, échéance" do
    S.books
    sale
    filing = S.liasse
    filing.kind.should eq("liasse")
    filing.forms.should eq(%w[2065 2033])
    filing.status.should eq("prepared")
    filing.company_name.should eq("Atelier Brunet SARL")
    filing.siren.should eq("732829320")
    filing.due_on.should eq(Time.utc(2027, 5, 19))
    filing.balance.map(&.account).should contain("706")
    row = filing.balance.find! { |item| item.account == "706" }
    row.credit.should eq(BigDecimal.new(1000))
    row.balance_credit.should eq(BigDecimal.new(1000))
    filing.total_debit.should eq(filing.total_credit)
    filing.ready?.should be_true
    filing.warnings.map(&.key).should contain("teledec.controls.fiscal_year_open")
    # Le document est la balance et l'identité : aucune case calculée.
    filing.boxes.should be_empty
    payload = JSON.parse(String.new(Api.export_file(S.admin, filing.id).content))
    payload["schema"].should eq("partiduo-teledec/1")
    payload["identity"]["siren"].should eq("732829320")
    payload["forms"].as_a.map(&.as_s).should eq(%w[2065 2033])
  end

  it "écarte l'écriture de clôture de la balance transmise" do
    S.books
    sale("800")
    ledger = Books.ledger("O01")
    Acc.post_closing_entry(S::SYSTEM, Acc::ClosingInput.new(fiscal_year_id: S.fiscal_year_id, ledger_id: ledger.id,
      profit_account: "120", loss_account: "120")).value!
    filing = S.liasse
    filing.balance.find! { |item| item.account == "706" }.balance_credit.should eq(BigDecimal.new(800))
    filing.balance.any? { |item| item.account == "120" }.should be_false
    filing.details["closing_neutralised"].should eq("1")
  end

  it "suit le régime : BIC à l'IR au réel normal, SCI ; refuse sans régime ou hors de France" do
    S.books("bic_rn")
    S.liasse.forms.should eq(%w[2031 2050])
    Api.update_settings(S::SYSTEM, Api::SettingsInput.new("sci", "none")).value!
    S.liasse.forms.should eq(%w[2072])
    Api.update_settings(S::SYSTEM, Api::SettingsInput.new("", "none")).value!
    Api.prepare(S.admin, Api::PrepareInput.new("liasse", fiscal_year_id: S.fiscal_year_id)).error_keys
      .should eq(["teledec.errors.settings.tax_system"])
    Api.prepare(S.admin, Api::PrepareInput.new("liasse", fiscal_year_id: 999_999_i64)).error_keys
      .should eq(["teledec.errors.fiscal_year.unknown"])
    Api.prepare(S.admin, Api::PrepareInput.new("bilan")).error_keys.should eq(["teledec.errors.kind.unknown"])
  end

  it "joint la balance de l'exercice précédent" do
    S.books
    PartiduoUi::Reference.fiscal_year(2027)
    next_year = Partiduo::Api::Core.fiscal_years(S::SYSTEM).find! { |year| year.year == 2027 }
    sale
    filing = S.prepare("liasse", fiscal_year_id: next_year.id)
    filing.previous_balance_rows.should be > 0
  end

  it "reprend la 2035 préparée par le module liberal pour un BNC" do
    S.books("bnc", "none")
    Partiduo::Api::Modules.activate(S::SYSTEM, "LIBERAL").value!
    filing = S.liasse
    filing.forms.should eq(%w[2035])
    filing.details["tax_return_fingerprint"].size.should eq(64)
    prepared = Partiduo::Api::Liberal.tax_return(S::SYSTEM, 2026)
    filing.details["tax_return_fingerprint"].should eq(prepared.fingerprint)
    unless prepared.ready?
      filing.errors.map(&.key).should contain("teledec.controls.liberal_not_ready")
    end
  end

  it "exporte la balance au format d'import (repli)" do
    S.books
    sale("1234.5")
    file = Api.balance_file(S.admin, S.fiscal_year_id)
    file.filename.should eq("732829320-balance-20261231.csv")
    text = String.new(file.content)
    text.should start_with("﻿Compte;Intitulé;Débit;Crédit;Solde débiteur;Solde créditeur\r\n")
    text.should contain(";0,00;1234,50;0,00;1234,50\r\n")
  end
end
