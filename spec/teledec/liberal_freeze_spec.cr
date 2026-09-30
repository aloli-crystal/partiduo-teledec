# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Teledec::SpecSupport
private alias Api = Teledec::Api
private alias Lib = Partiduo::Api::Liberal

private def year_2026 : Nil
  S.liberal_line("receipt", "2026-03-01", "42000", "RECEIPTS")
  S.liberal_line("expense", "2026-03-04", "9600", "RENT")
end

private def prepared(actor : Partiduo::Api::Actor) : Api::FilingView
  Api.prepare(actor, Api::PrepareInput.new(kind: "liasse", fiscal_year_id: S.fiscal_year_id)).value!
end

# DECISIONS D-LIB2-003 : la transmission de la 2035 préparée par le module
# `liberal` fige son exercice. L'extension n'appelle aucune commande du
# module : elle publie `tax_return.transmitted` (et `tax_return.rejected` si
# le dépôt est rejeté) dans la transaction qui note le dépôt.
describe "2035 transmise : l'exercice du module liberal est figé (D-LIB2-003)" do
  it "fige l'exercice à la transmission par TELEDEC, sans toucher l'exercice suivant" do
    S.liberal_books
    S.connect
    year_2026
    actor = S.admin(S::LIBERAL)
    filing = prepared(actor)
    Lib.year(S::SYSTEM, 2026).open?.should be_true
    line = Lib.lines(S::SYSTEM).first
    Lib.update_line(S::SYSTEM, line.id, Lib::LineInput.new(date: line.date, nature_id: line.nature_id,
      amount: BigDecimal.new(42100), method: "transfer")).success?.should be_true
    # La 2035 a changé depuis la préparation : la transmission est refusée.
    Api.transmit(actor, filing.id).error_keys.should eq(["teledec.errors.filing.changed"])
    filing = prepared(actor)
    Api.transmit(actor, filing.id).value!.status.should eq("transmitted")

    year = Lib.year(S::SYSTEM, 2026)
    {year.state, year.reference}.should eq({"transmitted", "teledec:#{filing.id}"})
    year.frozen_fingerprint.should eq(filing.details["tax_return_fingerprint"])
    Lib.line(S::SYSTEM, line.id).locked.should be_true
    Lib.update_line(S::SYSTEM, line.id, Lib::LineInput.new(date: line.date, nature_id: line.nature_id,
      amount: BigDecimal.new(1), method: "transfer")).error_keys.should eq(["liberal.errors.line.change.transmitted"])
    Lib.delete_line(S::SYSTEM, line.id).error_keys.should eq(["liberal.errors.line.change.transmitted"])
    Lib.tax_return(S::SYSTEM, 2026).fingerprint.should eq(filing.details["tax_return_fingerprint"])
    Lib.year(S::SYSTEM, 2027).open?.should be_true
  end

  it "rend l'exercice modifiable quand TELEDEC rejette le dépôt" do
    S.liberal_books
    S.connect
    year_2026
    actor = S.admin(S::LIBERAL)
    filing = Api.transmit(actor, prepared(actor).id).value!
    Lib.year(S::SYSTEM, 2026).state.should eq("transmitted")
    remote = S.teledec.deposits.keys.first
    S.teledec.reject(remote, "Montants à revoir")
    Api.refresh(actor, filing.id).value!.status.should eq("rejected")
    Lib.year(S::SYSTEM, 2026).open?.should be_true
    line = Lib.lines(S::SYSTEM).first
    Lib.update_line(S::SYSTEM, line.id, Lib::LineInput.new(date: line.date, nature_id: line.nature_id,
      amount: BigDecimal.new(41000), method: "transfer")).success?.should be_true
    # Préparée de nouveau et transmise : figée de nouveau, sous le même dépôt.
    Api.transmit(actor, prepared(actor).id).value!
    Lib.year(S::SYSTEM, 2026).state.should eq("transmitted")
  end

  it "fige aussi l'exercice d'un dépôt noté à la main, avec la Comptabilité" do
    S.liberal_books(accounting: true)
    Api.update_settings(S::SYSTEM, Api::SettingsInput.new("bnc", "none")).value!
    year_2026
    actor = S.admin(S::ALL + ["liberal.register.read"])
    filing = prepared(actor)
    filing.details["tax_return_fingerprint"]?.should_not be_nil
    Api.record_outcome(actor, filing.id, Api::OutcomeInput.new("transmitted")).value!
    Lib.year(S::SYSTEM, 2026).state.should eq("transmitted")
    Lib.lines(S::SYSTEM).all?(&.locked).should be_true
  end
end
