# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Teledec::SpecSupport
private alias Api = Teledec::Api
private alias Acc = Partiduo::Api::Accounting
private alias Books = PartiduoUi::Books

private def march_ca3(close : Bool = true) : Acc::VatReturnView
  customer = Books.card("CUSTOMER", "Atelier Morel").code
  Books.sale(customer, "1000", "2026-03-10")
  created = Acc.create_vat_return(S::SYSTEM, Acc::VatReturnInput.new(form: "fr_ca3", year: 2026, periodicity: "month", number: 3)).value!
  close ? Acc.close_vat_return(S::SYSTEM, (created.id || raise("déclaration sans identifiant")), nil).value! : created
end

describe "TVA CA3 et CA12 (déclarations du lot 4)" do
  it "reprend les cases d'une CA3 close de la Comptabilité, en euros entiers" do
    S.books
    vat = march_ca3
    filing = S.prepare("vat_ca3", vat_return_id: vat.id)
    filing.key.should eq("vat_ca3:2026-03-01")
    filing.forms.should eq(["3310-CA3"])
    filing.period_from.should eq(Time.utc(2026, 3, 1))
    filing.due_on.should eq(Time.utc(2026, 4, 19))
    filing.boxes.should_not be_empty
    filing.boxes.all? { |box| box.amount == box.amount.round(0) }.should be_true
    filing.boxes.map(&.box).should contain("28")
    filing.ready?.should be_true
    # L'échéancier relie la période à la déclaration close.
    deadline = Api.schedule(S.admin, S.fiscal_year_id).find! { |item| item.key == "vat_ca3:2026-03-01" }
    deadline.vat_return_id.should eq(vat.id)
    deadline.status.should eq("prepared")
  end

  it "refuse une déclaration de TVA ouverte, inconnue ou d'un autre formulaire" do
    S.books
    vat = march_ca3(close: false)
    Api.prepare(S.admin, Api::PrepareInput.new("vat_ca3", vat_return_id: vat.id)).error_keys
      .should eq(["teledec.errors.vat_return.open"])
    Api.prepare(S.admin, Api::PrepareInput.new("vat_ca12", vat_return_id: vat.id)).error_keys
      .should eq(["teledec.errors.vat_return.form"])
    Api.prepare(S.admin, Api::PrepareInput.new("vat_ca3", vat_return_id: 424_242_i64)).error_keys
      .should eq(["teledec.errors.vat_return.unknown"])
  end

  it "avertit quand le régime de TVA des paramètres ne prévoit pas le formulaire" do
    S.books(vat_system: "ca12")
    filing = S.prepare("vat_ca3", vat_return_id: march_ca3.id)
    filing.warnings.map(&.key).should contain("teledec.controls.vat_system")
  end
end

describe "DAS2 (honoraires, depuis les fiches fournisseurs et les écritures)" do
  it "déclare les bénéficiaires au-delà du seuil, toutes taxes comprises, en euros entiers" do
    S.books
    lawyer = S.supplier("Cabinet Durand")
    small = S.supplier("Conseil Petit")
    no_siret = S.supplier("Agence Sans Siret", siret: nil)
    S.fees(lawyer, "600", "2026-02-10")
    S.fees(lawyer, "400", "2026-09-10")
    S.fees(small, "300")
    S.fees(no_siret, "2000", account: "6222")
    filing = S.prepare("das2", year: 2026)
    filing.key.should eq("das2:2026")
    filing.due_on.should eq(Time.utc(2027, 5, 4))
    filing.das2.map(&.name).sort!.should eq(["Agence Sans Siret", "Cabinet Durand"])
    durand = filing.das2.find! { |line| line.name == "Cabinet Durand" }
    durand.total.should eq(BigDecimal.new(1200)) # 1 000 HT + 20 % de TVA
    durand.amounts.should eq({"fees" => BigDecimal.new(1200)})
    durand.siret.should eq(S::SIRET)
    durand.address.should eq("3 rue des Lilas, 69003 Lyon")
    agency = filing.das2.find! { |line| line.name == "Agence Sans Siret" }
    agency.amounts.should eq({"commissions" => BigDecimal.new(2400)})
    filing.warnings.map(&.key).should contain("teledec.controls.das2_siret")
    filing.ready?.should be_true
  end

  it "bloque une DAS2 sans bénéficiaire ou dont un bénéficiaire n'a pas d'adresse" do
    S.books
    Api.prepare(S.admin, Api::PrepareInput.new("das2")).error_keys.should eq(["teledec.errors.year.blank"])
    S.prepare("das2", year: 2026).errors.map(&.key).should eq(["teledec.controls.das2_empty"])
    S.fees(S.supplier("Sans Adresse", address: false), "1500")
    S.prepare("das2", year: 2026).errors.map(&.key).should eq(["teledec.controls.das2_address"])
  end

  it "suit les comptes et le seuil paramétrés" do
    S.books
    S.fees(S.supplier("Cabinet Durand"), "500")
    S.prepare("das2", year: 2026).errors.map(&.key).should eq(["teledec.controls.das2_empty"])
    Api.update_settings(S::SYSTEM, Api::SettingsInput.new("is_rsi", "ca3_monthly", das2_threshold: BigDecimal.new(100))).value!
    S.prepare("das2", year: 2026).das2.size.should eq(1)
    Api.update_settings(S::SYSTEM, Api::SettingsInput.new("is_rsi", "ca3_monthly", das2_accounts: {"6222" => "commissions"})).value!
    S.prepare("das2", year: 2026).errors.map(&.key).should eq(["teledec.controls.das2_empty"])
    Api.update_settings(S::SYSTEM, Api::SettingsInput.new("is_rsi", "ca3_monthly", das2_accounts: {"62x" => "fees"})).error_keys
      .should eq(["teledec.errors.settings.das2_account"])
  end
end
