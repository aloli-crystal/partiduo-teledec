# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Teledec::SpecSupport
private alias Api = Teledec::Api
private alias Books = PartiduoUi::Books

private def sale(amount : String = "1000") : Nil
  Books.sale(Books.card("CUSTOMER", "Client #{amount}").code, amount)
  nil
end

describe "Transmission et suivi des dépôts (ADR-007 D4)" do
  it "transmet, suit l'accusé de réception et le conserve en pièce jointe" do
    S.books
    sale
    filing = S.liasse
    Api.transmit(S.admin, filing.id).error_keys.should eq(["teledec.errors.credentials.missing"])
    S.connect
    sent = Api.transmit(S.admin, filing.id).value!
    sent.status.should eq("transmitted")
    sent.remote_id.should eq("TD-000001")
    deposit = S.teledec.deposits["TD-000001"]
    deposit.submission.kind.should eq("liasse")
    deposit.submission.fingerprint.should eq(filing.fingerprint)
    deposit.submission.reference.should eq("partiduo-#{filing.id}-1-#{filing.fingerprint[0, 16]}")
    deposit.credentials_env.should eq("sandbox")
    # Pas encore d'accusé.
    Api.refresh(S.admin, filing.id).value!.status.should eq("transmitted")
    S.teledec.acknowledge("TD-000001")
    done = Api.refresh(S.admin, filing.id).value!
    done.status.should eq("acknowledged")
    done.acknowledged_at.should eq(Time.utc(2027, 5, 10))
    receipt = Api.receipt_file(S.admin, filing.id) || raise "accusé absent"
    receipt.filename.should eq("accuse-TD-000001.pdf")
    String.new(receipt.content).should start_with("%PDF-1.4")
    Api.events(S.admin, filing.id).map(&.status).should eq(%w[prepared transmitted acknowledged])
    # Un dépôt accusé ne se prépare plus.
    Api.prepare(S.admin, Api::PrepareInput.new("liasse", fiscal_year_id: S.fiscal_year_id)).error_keys
      .should eq(["teledec.errors.filing.locked"])
    Api.transmit(S.admin, filing.id).error_keys.should eq(["teledec.errors.filing.status"])
  end

  it "note le rejet avec son motif, puis laisse préparer et transmettre de nouveau" do
    S.books
    sale
    S.connect
    filing = S.liasse
    Api.transmit(S.admin, filing.id).value!
    S.teledec.reject("TD-000001", "SIREN inconnu de la DGFiP")
    Api.refresh_all(S.admin).should eq(1)
    rejected = Api.filing(S.admin, filing.id)
    rejected.status.should eq("rejected")
    rejected.rejection_reason.should eq("SIREN inconnu de la DGFiP")
    again = S.liasse
    again.id.should eq(filing.id)
    again.status.should eq("prepared")
    Api.transmit(S.admin, filing.id).value!.remote_id.should eq("TD-000002")
    S.teledec.deposits["TD-000002"].submission.reference.should start_with("partiduo-#{filing.id}-2-")
  end

  it "refuse de transmettre un document modifié depuis la préparation ou bloqué par un contrôle" do
    S.books
    S.connect
    empty = S.liasse
    empty.errors.map(&.key).should eq(["teledec.controls.balance_empty"])
    Api.transmit(S.admin, empty.id).error_keys.should eq(["teledec.errors.filing.not_ready"])
    sale
    Api.transmit(S.admin, empty.id).error_keys.should eq(["teledec.errors.filing.changed"])
    Api.check(S.admin, empty.id).value!.errors.map(&.key).should contain("teledec.controls.changed")
    fresh = S.liasse
    fresh.ready?.should be_true
    Api.check(S.admin, fresh.id).value!.ready?.should be_true
  end

  it "note l'erreur du transport sans changer le statut" do
    S.books
    sale
    S.connect
    filing = S.liasse
    S.teledec.failure = "teledec.errors.transport.refused"
    Api.transmit(S.admin, filing.id).error_keys.should eq(["teledec.errors.transport.refused"])
    view = Api.filing(S.admin, filing.id)
    view.status.should eq("prepared")
    view.last_error.should eq("teledec.errors.transport.refused")
    Api.events(S.admin, filing.id).last.status.should eq("error")
  end

  it "sans transport branché, prépare, exporte et laisse noter le dépôt fait sur le site de TELEDEC" do
    S.books
    sale
    Teledec::Transports.current = nil
    filing = S.liasse
    Api.transmit(S.admin, filing.id).error_keys.should eq(["teledec.errors.transport.unavailable"])
    Api.settings(S.admin).transport.should be_nil
    Api.record_outcome(S.admin, filing.id, Api::OutcomeInput.new("rejected")).error_keys
      .should eq(["teledec.errors.outcome.reason"])
    sent = Api.record_outcome(S.admin, filing.id, Api::OutcomeInput.new("transmitted", reference: "WEB-42")).value!
    sent.status.should eq("transmitted")
    sent.manual.should be_true
    sent.remote_id.should eq("WEB-42")
    pdf = "%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n"
    done = Api.record_outcome(S.admin, filing.id, Api::OutcomeInput.new("acknowledged", receipt_filename: "accuse.pdf",
      receipt_content_type: "application/pdf", receipt: IO::Memory.new(pdf))).value!
    done.status.should eq("acknowledged")
    done.receipt_attachment_id.should_not be_nil
    Api.record_outcome(S.admin, filing.id, Api::OutcomeInput.new("rejected", reason: "x")).error_keys
      .should eq(["teledec.errors.filing.status"])
  end

  it "chiffre les identifiants de l'API et refuse ceux que TELEDEC ne reconnaît pas" do
    S.books
    Api.save_credentials(S::SYSTEM, Api::CredentialsInput.new("cabinet-test", "mauvaise-cle")).error_keys
      .should eq(["teledec.errors.transport.credentials"])
    S.connect
    stored = Teledec::Settings.current || raise "paramètres absents"
    stored.api_key.to_s.should start_with("v1:")
    stored.api_key.to_s.should_not contain(Teledec::SimulatedTeledec::API_KEY)
    view = Api.settings(S.admin)
    view.key_stored.should be_true
    view.login.should eq(Teledec::SimulatedTeledec::LOGIN)
    view.checked_at.should_not be_nil
    # Clé vide : la clé enregistrée est gardée.
    Api.save_credentials(S::SYSTEM, Api::CredentialsInput.new(Teledec::SimulatedTeledec::LOGIN, "", "production")).value!.env
      .should eq("production")
    Api.clear_credentials(S.admin).key_stored.should be_false
    Api.save_credentials(S::SYSTEM, Api::CredentialsInput.new("x", "", "lune")).error_keys
      .should eq(["teledec.errors.credentials.env", "teledec.errors.credentials.api_key"])
  end

  it "garde intangible le document d'un dépôt transmis (déclencheur en base)" do
    S.books
    sale
    S.connect
    filing = S.liasse
    Api.transmit(S.admin, filing.id).value!
    row = Teledec::Filing.get!(id: filing.id)
    row.payload = "{}"
    expect_raises(Exception, /intangible/) { row.save! }
  end

  it "contrôle les permissions et l'activation de l'extension" do
    S.books
    sale
    filing = S.liasse
    reader = S.admin([Api::READ, "accounting.report.read"])
    Api.filing(reader, filing.id).id.should eq(filing.id)
    expect_raises(Partiduo::Api::Forbidden) { Api.transmit(reader, filing.id) }
    expect_raises(Partiduo::Api::Forbidden) { Api.prepare(S.admin([Api::PREPARE]), Api::PrepareInput.new("liasse", fiscal_year_id: S.fiscal_year_id)) }
    expect_raises(Partiduo::Api::Forbidden) { Api.update_settings(reader, Api::SettingsInput.new("is_rsi", "ca12")) }
    Partiduo::Api::Modules.deactivate(S::SYSTEM, Teledec::CODE).value!
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.filings(S.admin) }
  end
end
