# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Teledec::SpecSupport
private alias Api = Teledec::Api
private alias Acc = Partiduo::Api::Accounting
private alias Books = PartiduoUi::Books

# Écriture d'opérations diverses sans fiche de tiers.
private def od(day : String, lines : Array({String, Acc::Side, String})) : Acc::EntryView
  input = Acc::EntryInput.new(ledger_id: Books.ledger("O01").id, date: Books.date(day), label: "OD",
    receipt: "OD-#{day}", lines: lines.map { |(account, side, amount)| Acc::EntryLineInput.new(account, side, Books.d(amount)) })
  Acc.post_entry(S::SYSTEM, input).value!
end

describe "DAS2 : règles de calcul (D-TDC-007)" do
  it "ne déclare que les sommes qui dépassent le seuil de 1 200 € (CGI, art. 240)" do
    S.books
    exact = S.supplier("Cabinet Exact")
    above = S.supplier("Cabinet Au-delà")
    S.fees(exact, "1000")    # 1 200,00 TTC : pas au-delà du seuil
    S.fees(above, "1000.34") # 1 200,41 TTC : au-delà, déclaré pour 1 200 €
    filing = S.prepare("das2", year: 2026)
    filing.das2.map(&.name).should eq(["Cabinet Au-delà"])
    filing.das2.first.total.should eq(BigDecimal.new(1200))
    filing.details["threshold"].should eq("1200")
  end

  it "additionne les natures d'un même bénéficiaire pour apprécier le seuil" do
    S.books
    code = S.supplier("Conseil Martin")
    S.fees(code, "600")                  # honoraires : 720 TTC
    S.fees(code, "500", account: "6222") # commissions : 600 TTC
    line = S.prepare("das2", year: 2026).das2.find! { |item| item.card_code == code }
    line.amounts.should eq({"fees" => BigDecimal.new(720), "commissions" => BigDecimal.new(600)})
    line.total.should eq(BigDecimal.new(1320))
  end

  it "retranche les factures extournées et ne retient que l'année civile demandée" do
    S.books
    PartiduoUi::Reference.fiscal_year(2027)
    code = S.supplier("Cabinet Durand")
    cancelled = S.fees(code, "3000", "2026-03-10")
    Acc.cancel_entry(S::SYSTEM, Acc::CancelEntryInput.new(entry_id: cancelled.id, date: Books.date("2026-03-20"))).value!
    S.prepare("das2", year: 2026).errors.map(&.key).should eq(["teledec.controls.das2_empty"])
    S.fees(code, "2000", "2027-01-05")
    S.prepare("das2", year: 2026).errors.map(&.key).should eq(["teledec.controls.das2_empty"])
    next_year = S.prepare("das2", year: 2027)
    next_year.key.should eq("das2:2027")
    next_year.due_on.should eq(Time.utc(2028, 5, 3))
    next_year.das2.first.total.should eq(BigDecimal.new(2400))
  end

  it "avertit pour une écriture d'honoraires sans fiche de tiers, sans la déclarer" do
    S.books
    od("2026-06-10", [{"6226", Acc::Side::Debit, "1500"}, {"444", Acc::Side::Credit, "1500"}])
    filing = S.prepare("das2", year: 2026)
    orphan = filing.warnings.find! { |item| item.key == "teledec.controls.das2_orphan" }
    orphan.params["amount"].should eq("1500.00")
    orphan.params["receipt"].should eq("OD-2026-06-10")
    filing.errors.map(&.key).should eq(["teledec.controls.das2_empty"])
  end

  it "déclare tout montant positif avec un seuil nul, et refuse un seuil négatif ou une nature inconnue" do
    S.books
    S.fees(S.supplier("Petit Conseil"), "10")
    Api.update_settings(S::SYSTEM, Api::SettingsInput.new("is_rsi", "ca3_monthly", das2_threshold: BigDecimal.new(0))).value!
    S.prepare("das2", year: 2026).das2.first.total.should eq(BigDecimal.new(12))
    Api.update_settings(S::SYSTEM, Api::SettingsInput.new("is_rsi", "ca3_monthly", das2_threshold: BigDecimal.new(-1)))
      .error_keys.should eq(["teledec.errors.settings.das2_threshold"])
    Api.update_settings(S::SYSTEM, Api::SettingsInput.new("is_rsi", "ca3_monthly", das2_accounts: {"6226" => "salaires"}))
      .error_keys.should eq(["teledec.errors.settings.das2_account"])
    # Comptes vides : retour aux comptes par défaut.
    Api.update_settings(S::SYSTEM, Api::SettingsInput.new("is_rsi", "ca3_monthly", das2_accounts: {} of String => String))
      .value!.das2_accounts.should eq(Teledec::Config::DAS2_ACCOUNTS)
  end
end

describe "DAS2 : TVA et écritures de fin d'exercice (relecture du lot T)" do
  it "n'ajoute pas de TVA à une ligne d'honoraires exonérée voisine d'une ligne taxée" do
    S.books
    code = S.supplier("Cabinet Mixte")
    Acc.create_account(S::SYSTEM, Acc::AccountInput.new(number: "6064", label: "Fournitures", parent: "60")).value!
    input = Acc::DocumentInput.new(ledger_id: Books.ledger("A01").id, date: Books.date("2026-05-10"), third_party: code,
      lines: [Acc::DocumentLineInput.new(amount: Books.d("2000"), account: "6226"),
              Acc::DocumentLineInput.new(amount: Books.d("100"), account: "6064", vat_rate: "NOR")], label: "Honoraires et fournitures")
    Acc.post_purchase(S::SYSTEM, input).value!
    line = S.prepare("das2", year: 2026).das2.find! { |item| item.card_code == code }
    line.total.should eq(BigDecimal.new(2000))
  end

  it "n'ajoute pas la TVA autoliquidée, que le prestataire n'a pas perçue" do
    S.books
    code = S.supplier("Cabinet Européen")
    input = Acc::DocumentInput.new(ledger_id: Books.ledger("A01").id, date: Books.date("2026-05-10"), third_party: code,
      lines: [Acc::DocumentLineInput.new(amount: Books.d("2000"), account: "6226", vat_rate: "INTS")], label: "Honoraires UE")
    entry = Acc.post_purchase(S::SYSTEM, input).value!
    entry.lines.count { |item| item.vat_role == "tax" }.should eq(2)
    S.prepare("das2", year: 2026).das2.find! { |item| item.card_code == code }.total.should eq(BigDecimal.new(2000))
  end

  it "écarte l'écriture de clôture : pas d'avertissement d'écriture sans fiche" do
    S.books
    code = S.supplier("Cabinet Durand")
    S.fees(code, "2000")
    Acc.post_closing_entry(S::SYSTEM, Acc::ClosingInput.new(fiscal_year_id: S.fiscal_year_id, ledger_id: Books.ledger("O01").id,
      profit_account: "120", loss_account: "120")).value!
    filing = S.prepare("das2", year: 2026)
    filing.warnings.map(&.key).should_not contain("teledec.controls.das2_orphan")
    filing.das2.find! { |item| item.card_code == code }.total.should eq(BigDecimal.new(2400))
  end
end

describe "Relevé de solde d'IS : impôt repris du compte 695 (D-TDC-009)" do
  it "reprend le solde du compte 695 quand l'impôt n'est pas saisi, et déduit seulement les acomptes transmis" do
    S.books
    od("2026-12-31", [{"695", Acc::Side::Debit, "5000.40"}, {"444", Acc::Side::Credit, "5000.40"}])
    S.connect
    first = S.prepare("is_2571", fiscal_year_id: S.fiscal_year_id, number: 1, amount: BigDecimal.new(1000))
    Api.transmit(S.admin, first.id).value!
    second = S.prepare("is_2571", fiscal_year_id: S.fiscal_year_id, number: 2, amount: BigDecimal.new(1000))
    Api.record_outcome(S.admin, second.id, Api::OutcomeInput.new("acknowledged")).value!
    S.prepare("is_2571", fiscal_year_id: S.fiscal_year_id, number: 3, amount: BigDecimal.new(1000)) # préparé seulement
    solde = S.prepare("is_2572", fiscal_year_id: S.fiscal_year_id)
    solde.details.should eq({"tax" => "5000", "advances" => "2000", "balance" => "3000"})
    solde.warnings.map(&.key).should_not contain("teledec.controls.corporate_tax_zero")
    # Excédent d'acomptes : solde négatif (à restituer).
    S.prepare("is_2572", fiscal_year_id: S.fiscal_year_id, amount: BigDecimal.new(1500)).details["balance"].should eq("-500")
  end

  it "refuse un montant négatif et reprend le montant saisi pour contrôler de nouveau" do
    S.books
    Api.prepare(S.admin, Api::PrepareInput.new("is_2571", fiscal_year_id: S.fiscal_year_id, number: 1,
      amount: BigDecimal.new(-5))).error_keys.should eq(["teledec.errors.amount.invalid"])
    Api.prepare(S.admin, Api::PrepareInput.new("is_2571", fiscal_year_id: S.fiscal_year_id, number: 0,
      amount: BigDecimal.new(5))).error_keys.should eq(["teledec.errors.number.invalid"])
    advance = S.prepare("is_2571", fiscal_year_id: S.fiscal_year_id, number: 4, amount: BigDecimal.new("812.5"))
    advance.due_on.should eq(Time.utc(2026, 12, 15))
    advance.details["amount"].should eq("813")
    checked = Api.check(S.admin, advance.id).value!
    checked.errors.should be_empty
    checked.fingerprint.should eq(advance.fingerprint)
  end
end
