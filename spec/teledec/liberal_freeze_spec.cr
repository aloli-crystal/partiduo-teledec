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

# Clôture de l'exercice libéral, par le contrat du module (comme l'écran).
private def close(year : Int32 = 2026) : Nil
  Lib.close_year(S::SYSTEM, year).value!
end

# DECISIONS D-LIB2-003, D-LIB5-002, D-LIB5-003 : la 2035 préparée par le
# module `liberal` se transmet sur un exercice clôturé ; sa transmission le
# verrouille. L'extension n'appelle aucune commande du module : elle publie
# `tax_return.transmitted` (et `tax_return.rejected` si le dépôt est
# rejeté, ce qui rend l'exercice clôturé) dans la transaction qui note le
# dépôt.
describe "2035 transmise : l'exercice du module liberal est verrouillé (D-LIB2-003, D-LIB5)" do
  it "refuse de transmettre la 2035 d'un exercice ouvert, par l'API comme à la main" do
    S.liberal_books
    S.connect
    year_2026
    actor = S.admin(S::LIBERAL)
    filing = prepared(actor)
    filing.controls.map(&.key).should contain("teledec.controls.liberal_year_open")
    Api.transmit(actor, filing.id).error_keys.should eq(["teledec.errors.filing.liberal_year_open"])
    Api.record_outcome(actor, filing.id, Api::OutcomeInput.new("transmitted")).error_keys
      .should eq(["teledec.errors.filing.liberal_year_open"])
    S.teledec.deposits.should be_empty
    Lib.year(S::SYSTEM, 2026).open?.should be_true
    # Clôturé : le contrôle disparaît, la transmission passe.
    close
    filing = prepared(actor)
    filing.controls.map(&.key).should_not contain("teledec.controls.liberal_year_open")
    Api.transmit(actor, filing.id).value!.status.should eq("transmitted")
    Lib.year(S::SYSTEM, 2026).locked?.should be_true
  end

  it "verrouille l'exercice à la transmission par TELEDEC, sans toucher l'exercice suivant" do
    S.liberal_books
    S.connect
    year_2026
    actor = S.admin(S::LIBERAL)
    close
    filing = prepared(actor)
    Lib.year(S::SYSTEM, 2026).closed?.should be_true
    # Rouvert et corrigé après la préparation : il faut clôturer de nouveau,
    # puis préparer de nouveau.
    Lib.reopen_year(S::SYSTEM, 2026).value!
    line = Lib.lines(S::SYSTEM).first
    Lib.update_line(S::SYSTEM, line.id, Lib::LineInput.new(date: line.date, nature_id: line.nature_id,
      amount: BigDecimal.new(42100), method: "transfer")).success?.should be_true
    Api.transmit(actor, filing.id).error_keys.should eq(["teledec.errors.filing.liberal_year_open"])
    close
    # La 2035 a changé depuis la préparation : la transmission est refusée.
    Api.transmit(actor, filing.id).error_keys.should eq(["teledec.errors.filing.changed"])
    filing = prepared(actor)
    Api.transmit(actor, filing.id).value!.status.should eq("transmitted")

    year = Lib.year(S::SYSTEM, 2026)
    {year.state, year.reference}.should eq({"locked", "teledec:#{filing.id}"})
    Lib.reopen_year(S::SYSTEM, 2026).error_keys.should eq(["liberal.errors.year.reopen.locked"])
    year.frozen_fingerprint.should eq(filing.details["tax_return_fingerprint"])
    Lib.line(S::SYSTEM, line.id).locked.should be_true
    Lib.update_line(S::SYSTEM, line.id, Lib::LineInput.new(date: line.date, nature_id: line.nature_id,
      amount: BigDecimal.new(1), method: "transfer")).error_keys.should eq(["liberal.errors.line.change.transmitted"])
    Lib.delete_line(S::SYSTEM, line.id).error_keys.should eq(["liberal.errors.line.change.transmitted"])
    Lib.tax_return(S::SYSTEM, 2026).fingerprint.should eq(filing.details["tax_return_fingerprint"])
    Lib.year(S::SYSTEM, 2027).open?.should be_true
  end

  it "rend l'exercice clôturé quand TELEDEC rejette le dépôt : rouvert, corrigé, renvoyé" do
    S.liberal_books
    S.connect
    year_2026
    actor = S.admin(S::LIBERAL)
    close
    filing = Api.transmit(actor, prepared(actor).id).value!
    Lib.year(S::SYSTEM, 2026).state.should eq("locked")
    remote = S.teledec.deposits.keys.first
    S.teledec.reject(remote, "Montants à revoir")
    Api.refresh(actor, filing.id).value!.status.should eq("rejected")
    Lib.year(S::SYSTEM, 2026).state.should eq("closed")
    line = Lib.lines(S::SYSTEM).first
    Lib.update_line(S::SYSTEM, line.id, Lib::LineInput.new(date: line.date, nature_id: line.nature_id,
      amount: BigDecimal.new(41000), method: "transfer")).error_keys.should eq(["liberal.errors.line.change.year_closed"])
    Lib.reopen_year(S::SYSTEM, 2026).value!
    Lib.update_line(S::SYSTEM, line.id, Lib::LineInput.new(date: line.date, nature_id: line.nature_id,
      amount: BigDecimal.new(41000), method: "transfer")).success?.should be_true
    # Clôturée, préparée de nouveau et transmise : verrouillée de nouveau.
    close
    Api.transmit(actor, prepared(actor).id).value!
    Lib.year(S::SYSTEM, 2026).state.should eq("locked")
  end

  it "verrouille aussi l'exercice d'un dépôt noté à la main, avec la Comptabilité" do
    S.liberal_books(accounting: true)
    Api.update_settings(S::SYSTEM, Api::SettingsInput.new("bnc", "none")).value!
    year_2026
    actor = S.admin(S::ALL + ["liberal.register.read"])
    close
    filing = prepared(actor)
    filing.details["tax_return_fingerprint"]?.should_not be_nil
    Api.record_outcome(actor, filing.id, Api::OutcomeInput.new("transmitted")).value!
    Lib.year(S::SYSTEM, 2026).state.should eq("locked")
    Lib.lines(S::SYSTEM).all?(&.locked).should be_true
  end
end
