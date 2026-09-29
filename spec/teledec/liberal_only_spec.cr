# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Teledec::SpecSupport
private alias Api = Teledec::Api

private def liberal_admin : Partiduo::Api::Actor
  S.admin(S::LIBERAL)
end

# Année 2026 d'un kinésithérapeute tenue dans le livre-journal de `liberal`.
private def year_2026 : Nil
  S.liberal_line("receipt", "2026-03-01", "42000", "RECEIPTS")
  S.liberal_line("expense", "2026-03-04", "9600", "RENT")
  S.liberal_line("expense", "2026-03-05", "850", "OFFICE")
end

private def base_keys(result) : Array(String)
  result.errors.map(&.key)
end

# DECISIONS D-TDC2-001 à D-TDC2-004 : TELEDEC dépend de la Comptabilité *ou*
# du module `liberal` ; sans la Comptabilité, la 2035 seule.
describe "TELEDEC pour un libéral sans Comptabilité (D-TDC2)" do
  it "dépend de la Comptabilité ou du module liberal (depends_on_any)" do
    manifest = Partiduo::Modules["TELEDEC"]? || raise "manifeste absent"
    manifest.depends_on.should be_empty
    manifest.depends_on_any.should eq([%w[ACCOUNTING LIBERAL]])
  end

  it "s'active avec le module liberal seul, et le retient tant qu'il est la seule source" do
    S.liberal_books
    Partiduo::Modules.active?("ACCOUNTING").should be_false
    Partiduo::Modules.active?(Teledec::CODE).should be_true
    refused = Partiduo::Api::Modules.deactivate(S::SYSTEM, "LIBERAL")
    refused.failure?.should be_true
    Partiduo::Api::Modules.activate(S::SYSTEM, "ACCOUNTING").value!
    Partiduo::Api::Modules.deactivate(S::SYSTEM, "LIBERAL").success?.should be_true
  end

  it "ne propose que la liasse 2035, au régime BNC, dans les paramètres et les échéances" do
    S.liberal_books
    view = Api.settings(liberal_admin)
    {view.accounting, view.tax_system, view.kinds, view.tax_systems, view.forms}
      .should eq({false, "bnc", %w[liasse], %w[bnc], %w[2035]})
    deadlines = Api.schedule(liberal_admin, S.fiscal_year_id)
    deadlines.map(&.key).should eq(["liasse:#{S.fiscal_year_id}"])
    deadlines.first.forms.should eq(%w[2035])
    deadlines.first.due_on.should eq(Teledec::Calendar.liasse(Time.utc(2026, 12, 31)))
  end

  it "prépare la 2035 depuis celle du module liberal, sans balance" do
    S.liberal_books
    year_2026
    filing = Api.prepare(liberal_admin, Api::PrepareInput.new(kind: "liasse", fiscal_year_id: S.fiscal_year_id)).value!
    prepared = Partiduo::Api::Liberal.tax_return(S::SYSTEM, 2026)
    filing.forms.should eq(%w[2035])
    filing.balance.should be_empty
    filing.previous_balance_rows.should eq(0)
    filing.details["source"].should eq("liberal")
    filing.details["tax_return_fingerprint"].should eq(prepared.fingerprint)
    filing.boxes.find! { |box| box.form == "2035-A" && box.box == "AA" }.amount.should eq(BigDecimal.new(42000))
    filing.boxes.size.should eq(prepared.boxes.values.sum(&.size))
    keys = filing.controls.map(&.key)
    keys.should_not contain("teledec.controls.balance_empty")
    keys.should contain("teledec.controls.fiscal_year_open")
    prepared.ready?.should be_true
    filing.ready?.should be_true
  end

  it "bloque la 2035 que le module liberal n'estime pas prête" do
    S.liberal_books
    year_2026
    # Poste des loyers sans ligne au millésime : contrôle bloquant de `liberal`.
    rent = Partiduo::Api::Liberal.form_lines(S::SYSTEM, 2026).find!(&.item.==("rent"))
    Partiduo::Api::Liberal.delete_form_line(S::SYSTEM, rent.id).success?.should be_true
    filing = Api.prepare(liberal_admin, Api::PrepareInput.new(kind: "liasse", fiscal_year_id: S.fiscal_year_id)).value!
    Partiduo::Api::Liberal.tax_return(S::SYSTEM, 2026).ready?.should be_false
    filing.errors.map(&.key).should contain("teledec.controls.liberal_not_ready")
  end

  it "refuse, avec un message clair, les déclarations qui exigent la Comptabilité" do
    S.liberal_books
    inputs = [
      Api::PrepareInput.new(kind: "vat_ca3", vat_return_id: 1_i64),
      Api::PrepareInput.new(kind: "vat_ca12", vat_return_id: 1_i64),
      Api::PrepareInput.new(kind: "das2", year: 2026),
      Api::PrepareInput.new(kind: "is_2571", fiscal_year_id: S.fiscal_year_id, number: 1, amount: BigDecimal.new(100)),
      Api::PrepareInput.new(kind: "is_2572", fiscal_year_id: S.fiscal_year_id),
      Api::PrepareInput.new(kind: "greffe", fiscal_year_id: S.fiscal_year_id),
    ]
    inputs.each do |input|
      result = Api.prepare(liberal_admin, input)
      {input.kind, base_keys(result)}.should eq({input.kind, ["teledec.errors.accounting_required"]})
    end
    I18n.t("teledec.errors.accounting_required").should contain("nécessite le module Comptabilité")
    Teledec::Filing.all.count.should eq(0)
  end

  it "refuse un régime autre que BNC, puis la liasse d'un régime déjà enregistré" do
    S.liberal_books
    result = Api.update_settings(liberal_admin, Api::SettingsInput.new("is_rsi", "ca3_monthly"))
    result.errors.map { |error| {error.field, error.key} }.should eq([{"tax_system", "teledec.errors.accounting_required"}])
    Api.update_settings(liberal_admin, Api::SettingsInput.new("bnc", "none")).value!.tax_system.should eq("bnc")

    # Régime BIC choisi quand la Comptabilité était active : aucune
    # échéance, liasse refusée.
    Partiduo::Api::Modules.activate(S::SYSTEM, "ACCOUNTING").value!
    Api.update_settings(liberal_admin, Api::SettingsInput.new("bic_rsi", "none")).value!
    Partiduo::Api::Modules.deactivate(S::SYSTEM, "ACCOUNTING").value!
    Api.schedule(liberal_admin, S.fiscal_year_id).should be_empty
    base_keys(Api.prepare(liberal_admin, Api::PrepareInput.new(kind: "liasse", fiscal_year_id: S.fiscal_year_id)))
      .should eq(["teledec.errors.accounting_required"])
  end

  it "refuse l'export de la balance sans lire la Comptabilité" do
    S.liberal_books
    error = expect_raises(Api::AccountingRequired) { Api.balance_file(liberal_admin, S.fiscal_year_id) }
    error.key.should eq("teledec.errors.accounting_required")
    error.module_code.should eq("ACCOUNTING")
  end

  it "exige la lecture du livre-journal de liberal, pas les droits de la Comptabilité" do
    S.liberal_books
    input = Api::PrepareInput.new(kind: "liasse", fiscal_year_id: S.fiscal_year_id)
    expect_raises(Partiduo::Api::Forbidden) do
      Api.prepare(S.admin([Api::READ, Api::PREPARE, "accounting.report.read"]), input)
    end
    Api.prepare(S.admin([Api::READ, Api::PREPARE, "liberal.register.read"]), input).success?.should be_true
  end

  it "contrôle et transmet la 2035 sans balance ; un dépôt de TVA ancien ne se contrôle plus" do
    S.liberal_books
    year_2026
    S.connect
    filing = Api.prepare(liberal_admin, Api::PrepareInput.new(kind: "liasse", fiscal_year_id: S.fiscal_year_id)).value!
    Api.check(liberal_admin, filing.id).value!.controls.map(&.key).should_not contain("teledec.controls.changed")
    sent = Api.transmit(liberal_admin, filing.id).value!
    sent.status.should eq("transmitted")
    body = S.teledec.deposits[S::LIASSE_ID].body
    body.should contain("#CATEGORIE-FISCALE BNC")
    body.lines.none? { |line| line.count(';') == 7 }.should be_true
    zones = JSON.parse(body.lines.find!(&.starts_with?('{')))["zones_formulaires"]
    zones["2035A"]["AA"].as_i64.should eq(42000)
  end
end

describe "TELEDEC avec la Comptabilité (comportement inchangé, D-TDC2-001)" do
  it "propose toutes les déclarations, avec ou sans le module liberal" do
    S.books
    view = Api.settings(S.admin)
    {view.accounting, view.kinds, view.tax_systems}.should eq({true, Teledec::Config::KINDS, Teledec::Config::TAX_SYSTEMS})
    Api.schedule(S.admin, S.fiscal_year_id).map(&.kind).uniq!.sort!.should eq(%w[das2 is_2571 is_2572 liasse vat_ca3])
    Partiduo::Api::Modules.activate(S::SYSTEM, "LIBERAL").value!
    Api.settings(S.admin).kinds.should eq(Teledec::Config::KINDS)
  end

  it "joint la balance et les cases de liberal à la 2035 quand les deux sont actifs" do
    S.liberal_books(accounting: true)
    Api.update_settings(S::SYSTEM, Api::SettingsInput.new("bnc", "none")).value!
    year_2026
    filing = S.liasse
    filing.details["source"]?.should be_nil
    filing.details["tax_return_fingerprint"].size.should eq(64)
    filing.boxes.should_not be_empty
    filing.controls.map(&.key).should_not contain("teledec.errors.accounting_required")
    Api.balance_file(S.admin, S.fiscal_year_id).filename.should end_with(".csv")
  end
end
