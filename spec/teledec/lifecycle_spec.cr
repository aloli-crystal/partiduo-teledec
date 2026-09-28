# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Teledec::SpecSupport
private alias Api = Teledec::Api
private alias Books = PartiduoUi::Books

private def sale(amount : String = "1000") : Nil
  Books.sale(Books.card("CUSTOMER", "Client #{amount}").code, amount)
  nil
end

private def pdf : IO::Memory
  IO::Memory.new("%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n")
end

# TELEDEC qui accepte les dépôts mais ne répond plus sur leur état.
private class UnreachableStatus < Teledec::SimulatedTeledec
  def status(credentials : Teledec::Credentials, remote_id : String) : Teledec::RemoteStatus
    raise Teledec::TransportError.new("teledec.errors.transport.unreachable")
  end
end

describe "Cycle d'un dépôt : cas limites" do
  it "rejoue une transmission dont la réponse s'est perdue sans créer de second dépôt (idempotence)" do
    S.books
    sale
    S.connect
    filing = S.liasse
    # Premier envoi parvenu à TELEDEC, réponse perdue : rien n'est noté dans Partiduo.
    reference = "partiduo-#{filing.id}-1-#{filing.fingerprint[0, 16]}"
    credentials = Teledec::Credentials.new(Teledec::SimulatedTeledec::LOGIN, Teledec::SimulatedTeledec::API_KEY, "sandbox")
    S.teledec.submit(credentials, Teledec::Submission.new(reference, "liasse", %w[2065 2033], "{}", filing.fingerprint))
      .should eq("TD-000001")
    Api.filing(S.admin, filing.id).status.should eq("prepared")
    Api.transmit(S.admin, filing.id).value!.remote_id.should eq("TD-000001")
    S.teledec.deposits.size.should eq(1)
  end

  it "prépare de nouveau un dépôt préparé sur la même ligne, et garde l'historique" do
    S.books
    sale
    first = S.liasse
    sale("500")
    again = S.liasse
    again.id.should eq(first.id)
    again.fingerprint.should_not eq(first.fingerprint)
    Api.events(S.admin, first.id).map(&.status).should eq(%w[prepared prepared])
    Api.filings(S.admin, S.fiscal_year_id).map(&.id).should eq([first.id])
    Api.filings(S.admin, 987_654_i64).should be_empty
  end

  it "n'actualise que les dépôts transmis par le transport, et note son erreur" do
    S.books
    sale
    S.connect
    filing = S.liasse
    Api.refresh(S.admin, filing.id).error_keys.should eq(["teledec.errors.filing.status"])
    Api.check(S.admin, filing.id).value!.status.should eq("prepared")
    Api.transmit(S.admin, filing.id).value!
    Api.check(S.admin, filing.id).error_keys.should eq(["teledec.errors.filing.status"])
    Teledec::Transports.current = UnreachableStatus.new
    Api.refresh(S.admin, filing.id).error_keys.should eq(["teledec.errors.transport.unreachable"])
    Api.filing(S.admin, filing.id).last_error.should eq("teledec.errors.transport.unreachable")
    Api.refresh_all(S.admin).should eq(0)
    Api.filing(S.admin, filing.id).status.should eq("transmitted")
    Teledec::Transports.current = nil
    Api.refresh_all(S.admin).should eq(0)
    Api.refresh(S.admin, filing.id).error_keys.should eq(["teledec.errors.transport.unavailable"])
    Teledec::Transports.current = Teledec::SimulatedTeledec.new
    Api.clear_credentials(S.admin)
    Api.refresh(S.admin, filing.id).error_keys.should eq(["teledec.errors.credentials.missing"])
  end

  it "note à la main un rejet direct, puis laisse préparer de nouveau sans reprendre la pièce du rejet" do
    S.books
    sale
    Teledec::Transports.current = nil
    filing = S.liasse
    Api.record_outcome(S.admin, filing.id, Api::OutcomeInput.new("perdu")).error_keys
      .should eq(["teledec.errors.outcome.status"])
    rejected = Api.record_outcome(S.admin, filing.id, Api::OutcomeInput.new("rejected", reason: "  SIREN inconnu  ",
      reference: "WEB-1", receipt_filename: "rejet.pdf", receipt: pdf)).value!
    rejected.status.should eq("rejected")
    rejected.manual.should be_true
    rejected.rejection_reason.should eq("SIREN inconnu")
    rejected.receipt_attachment_id.should_not be_nil
    Api.events(S.admin, filing.id).map(&.status).should eq(%w[prepared transmitted rejected])
    # Un dépôt noté à la main ne s'actualise pas auprès de TELEDEC.
    Api.refresh(S.admin, filing.id).error_keys.should eq(["teledec.errors.filing.status"])
    again = S.liasse
    again.status.should eq("prepared")
    again.manual.should be_false
    again.remote_id.should eq("")
    again.rejection_reason.should eq("")
    again.receipt_attachment_id.should be_nil
    Api.receipt_file(S.admin, filing.id).should be_nil
  end

  it "note un dépôt transmis à la main, puis son accusé sans pièce, et refuse une seconde transmission" do
    S.books
    sale
    Teledec::Transports.current = nil
    filing = S.liasse
    long = "R" * 300
    sent = Api.record_outcome(S.admin, filing.id, Api::OutcomeInput.new("transmitted", reference: long)).value!
    sent.remote_id.size.should eq(128)
    Api.record_outcome(S.admin, filing.id, Api::OutcomeInput.new("transmitted")).error_keys
      .should eq(["teledec.errors.filing.status"])
    done = Api.record_outcome(S.admin, filing.id, Api::OutcomeInput.new("acknowledged")).value!
    done.status.should eq("acknowledged")
    done.acknowledged_at.should_not be_nil
    Api.receipt_file(S.admin, filing.id).should be_nil
    # Le document d'un dépôt accusé reste celui qui a été déposé.
    sale("300")
    Api.filing(S.admin, filing.id).fingerprint.should eq(filing.fingerprint)
  end

  it "rattache l'échéancier aux dépôts préparés et au statut de chacun" do
    S.books
    sale
    Teledec::Transports.current = nil
    liasse = S.liasse
    Api.record_outcome(S.admin, liasse.id, Api::OutcomeInput.new("transmitted")).value!
    schedule = Api.schedule(S.admin, S.fiscal_year_id)
    item = schedule.find! { |deadline| deadline.key == "liasse:#{S.fiscal_year_id}" }
    item.filing_id.should eq(liasse.id)
    item.status.should eq("transmitted")
    schedule.find! { |deadline| deadline.key == "das2:2026" }.filing_id.should be_nil
    expect_raises(Partiduo::Api::NotFound) { Api.schedule(S.admin, 987_654_i64) }
    expect_raises(Partiduo::Api::NotFound) { Api.filing(S.admin, 987_654_i64) }
    expect_raises(Partiduo::Api::NotFound) { Api.balance_file(S.admin, 987_654_i64) }
  end

  it "enregistre les identifiants sans les vérifier quand aucun transport n'est branché" do
    S.books
    Teledec::Transports.current = nil
    view = Api.save_credentials(S.admin, Api::CredentialsInput.new("  cabinet  ", "cle-quelconque")).value!
    view.login.should eq("cabinet")
    view.key_stored.should be_true
    view.checked_at.should be_nil
    view.transport.should be_nil
    stored = Teledec::Settings.current || raise "paramètres absents"
    Teledec::Secrets.decrypt(stored.api_key.to_s).should eq("cle-quelconque")
    Api.save_credentials(S.admin, Api::CredentialsInput.new("  ", "x")).error_keys.should eq(["teledec.errors.credentials.login"])
    Api.update_settings(S.admin, Api::SettingsInput.new("lmnp", "ca4")).error_keys
      .should eq(["teledec.errors.settings.tax_system_unknown", "teledec.errors.settings.vat_system_unknown"])
  end
end

describe "Droits et activation de l'extension (contrat Teledec::Api)" do
  it "exige la permission propre à chaque commande et les droits de la Comptabilité sur les sources" do
    S.books
    sale
    filing = S.liasse
    nobody = S.admin([] of String)
    reader = S.admin([Api::READ])
    preparer = S.admin([Api::READ, Api::PREPARE])
    expect_raises(Partiduo::Api::Forbidden) { Api.schedule(nobody, S.fiscal_year_id) }
    expect_raises(Partiduo::Api::Forbidden) { Api.filings(nobody) }
    expect_raises(Partiduo::Api::Forbidden) { Api.settings(nobody) }
    expect_raises(Partiduo::Api::Forbidden) { Api.export_file(nobody, filing.id) }
    Api.schedule(reader, S.fiscal_year_id).should_not be_empty
    Api.export_file(reader, filing.id).content_type.should eq("application/json")
    Api.receipt_file(reader, filing.id).should be_nil
    Api.settings(reader).key_stored.should be_false
    expect_raises(Partiduo::Api::Forbidden) { Api.balance_file(reader, S.fiscal_year_id) }
    expect_raises(Partiduo::Api::Forbidden) { Api.check(reader, filing.id) }
    # Préparer sans le droit de lire les éditions de la Comptabilité.
    expect_raises(Partiduo::Api::Forbidden) { Api.balance_file(preparer, S.fiscal_year_id) }
    expect_raises(Partiduo::Api::Forbidden) { Api.check(preparer, filing.id) }
    # La TVA exige le droit de déclarer la TVA.
    expect_raises(Partiduo::Api::Forbidden) do
      Api.prepare(S.admin([Api::PREPARE, "accounting.report.read"]), Api::PrepareInput.new("vat_ca3", vat_return_id: 1_i64))
    end
    # Transmettre, actualiser, noter une issue : `teledec.return.transmit`.
    expect_raises(Partiduo::Api::Forbidden) { Api.refresh(preparer, filing.id) }
    expect_raises(Partiduo::Api::Forbidden) { Api.refresh_all(preparer) }
    expect_raises(Partiduo::Api::Forbidden) { Api.record_outcome(preparer, filing.id, Api::OutcomeInput.new("transmitted")) }
    # Paramètres : `teledec.settings.manage`.
    expect_raises(Partiduo::Api::Forbidden) { Api.save_credentials(preparer, Api::CredentialsInput.new("a", "b")) }
    expect_raises(Partiduo::Api::Forbidden) { Api.clear_credentials(preparer) }
    Api.filing(S.admin, filing.id).status.should eq("prepared")
  end

  it "lève ModuleDisabled sur tout le contrat quand l'extension est inactive" do
    S.books
    sale
    filing = S.liasse
    Partiduo::Api::Modules.deactivate(S::SYSTEM, Teledec::CODE).value!
    admin = S.admin
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.settings(admin) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.update_settings(admin, Api::SettingsInput.new("is_rsi", "ca12")) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.save_credentials(admin, Api::CredentialsInput.new("a", "b")) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.clear_credentials(admin) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.schedule(admin, S.fiscal_year_id) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.filing(admin, filing.id) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.events(admin, filing.id) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.prepare(admin, Api::PrepareInput.new("liasse", fiscal_year_id: S.fiscal_year_id)) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.check(admin, filing.id) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.transmit(admin, filing.id) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.refresh(admin, filing.id) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.refresh_all(admin) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.record_outcome(admin, filing.id, Api::OutcomeInput.new("transmitted")) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.balance_file(admin, S.fiscal_year_id) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.export_file(admin, filing.id) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.receipt_file(admin, filing.id) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.transport_name(admin) }
    # Réactivée : les dépôts sont toujours là.
    Partiduo::Api::Modules.activate(S::SYSTEM, Teledec::CODE).value!
    Api.filing(admin, filing.id).status.should eq("prepared")
  end
end
