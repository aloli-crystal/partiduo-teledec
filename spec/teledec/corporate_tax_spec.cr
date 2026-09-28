# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Teledec::SpecSupport
private alias Api = Teledec::Api

describe "Relevés d'IS 2571 et 2572, dépôt des comptes au greffe" do
  it "prépare les acomptes et reprend ceux qui sont transmis dans le relevé de solde" do
    S.books
    S.connect
    first = S.prepare("is_2571", fiscal_year_id: S.fiscal_year_id, number: 1, amount: BigDecimal.new("2500.40"))
    first.key.should eq("is_2571:#{S.fiscal_year_id}:1")
    first.due_on.should eq(Time.utc(2026, 3, 15))
    first.details["amount"].should eq("2500")
    Api.transmit(S.admin, first.id).value!.status.should eq("transmitted")
    S.prepare("is_2571", fiscal_year_id: S.fiscal_year_id, number: 2, amount: BigDecimal.new(2500)) # préparé, non transmis
    solde = S.prepare("is_2572", fiscal_year_id: S.fiscal_year_id, amount: BigDecimal.new(9000))
    solde.details.should eq({"tax" => "9000", "advances" => "2500", "balance" => "6500"})
    solde.due_on.should eq(Time.utc(2027, 5, 15))
  end

  it "refuse les relevés d'IS hors impôt sur les sociétés, un numéro ou un montant invalides" do
    S.books("bic_rsi")
    Api.prepare(S.admin, Api::PrepareInput.new("is_2572", fiscal_year_id: S.fiscal_year_id)).error_keys
      .should eq(["teledec.errors.corporate_tax.not_applicable"])
    Api.update_settings(S::SYSTEM, Api::SettingsInput.new("is_rn", "ca12")).value!
    Api.prepare(S.admin, Api::PrepareInput.new("is_2571", fiscal_year_id: S.fiscal_year_id, number: 5, amount: BigDecimal.new(1))).error_keys
      .should eq(["teledec.errors.number.invalid"])
    Api.prepare(S.admin, Api::PrepareInput.new("is_2571", fiscal_year_id: S.fiscal_year_id, number: 1)).error_keys
      .should eq(["teledec.errors.amount.invalid"])
    S.prepare("is_2572", fiscal_year_id: S.fiscal_year_id).warnings.map(&.key).should contain("teledec.controls.corporate_tax_zero")
  end

  it "propose le dépôt des comptes au greffe seulement si l'option est active" do
    S.books
    Api.prepare(S.admin, Api::PrepareInput.new("greffe", fiscal_year_id: S.fiscal_year_id)).error_keys
      .should eq(["teledec.errors.greffe.disabled"])
    Api.schedule(S.admin, S.fiscal_year_id).map(&.kind).should_not contain("greffe")
    Api.update_settings(S::SYSTEM, Api::SettingsInput.new("is_rsi", "ca3_monthly", greffe: true)).value!
    filing = S.prepare("greffe", fiscal_year_id: S.fiscal_year_id, confidential: true)
    filing.forms.should eq(["greffe"])
    filing.details["confidential"].should eq("1")
    filing.due_on.should eq(Time.utc(2027, 7, 31))
  end

  it "liste les échéances de l'exercice selon les régimes" do
    S.books
    schedule = Api.schedule(S.admin, S.fiscal_year_id)
    schedule.count(&.kind.==("vat_ca3")).should eq(12)
    schedule.count(&.kind.==("is_2571")).should eq(4)
    schedule.map(&.kind).should contain("liasse")
    schedule.map(&.kind).should contain("das2")
    schedule.map(&.due_on).should eq(schedule.map(&.due_on).sort!)
    Api.update_settings(S::SYSTEM, Api::SettingsInput.new("bnc", "ca12")).value!
    kinds = Api.schedule(S.admin, S.fiscal_year_id).map(&.kind)
    kinds.should_not contain("is_2571")
    kinds.count(&.==("vat_ca12")).should eq(1)
  end
end
