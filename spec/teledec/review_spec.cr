# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Teledec::SpecSupport
private alias Api = Teledec::Api
private alias Books = PartiduoUi::Books

private def sale(amount : String = "1000") : Nil
  Books.sale(Books.card("CUSTOMER", "Client #{amount}").code, amount)
  nil
end

# TELEDEC qui reçoit le dépôt pendant qu'un autre utilisateur prépare de
# nouveau la déclaration.
private class ConcurrentPreparation < Teledec::SimulatedTeledec
  property during_submit : Proc(Nil)? = nil

  def submit(credentials : Teledec::Credentials, submission : Teledec::Submission) : String
    remote_id = super
    during_submit.try(&.call)
    remote_id
  end
end

private def with_transport(transport : Teledec::Transport, &) : Nil
  previous = Teledec::Transports.current
  Teledec::Transports.current = transport
  begin
    yield
  ensure
    Teledec::Transports.current = previous
  end
end

private def spoil_key : Nil
  settings = Teledec::Settings.current!
  settings.api_key = "v1:" + Base64.strict_encode(Bytes.new(80, 7_u8))
  settings.save!
  nil
end

describe "Relecture du lot T : cycle des dépôts" do
  it "annule tout un record_outcome dont la pièce est refusée : le dépôt reste préparé" do
    S.books
    sale
    filing = S.liasse
    input = Api::OutcomeInput.new("acknowledged", receipt_filename: "accuse.exe",
      receipt_content_type: "application/x-msdownload", receipt: IO::Memory.new("MZ binaire"))
    Api.record_outcome(S.admin, filing.id, input).error_keys.should eq(["core.errors.attachment.content_type.unsupported"])
    after = Api.filing(S.admin, filing.id)
    after.status.should eq("prepared")
    after.manual.should be_false
    Api.events(S.admin, filing.id).map(&.status).should eq(%w[prepared])
  end

  it "rend une erreur lisible quand la clé enregistrée ne se déchiffre plus, sans interrompre le suivi" do
    S.books
    sale
    S.connect
    filing = S.liasse
    Api.transmit(S.admin, filing.id).value!
    spoil_key
    Api.refresh(S.admin, filing.id).error_keys.should eq(["teledec.errors.credentials.unreadable"])
    Api.refresh_all(S.admin).should eq(0)
    Api.save_credentials(S::SYSTEM, Api::CredentialsInput.new(Teledec::SimulatedTeledec::LOGIN, ""))
      .error_keys.should eq(["teledec.errors.credentials.unreadable"])
    # Nouvelle saisie de la clé : le suivi reprend.
    S.connect
    S.teledec.acknowledge(Api.filing(S.admin, filing.id).remote_id)
    Api.refresh_all(S.admin).should eq(1)
  end

  it "refuse la transmission d'un dépôt préparé avec une clé illisible" do
    S.books
    sale
    S.connect
    filing = S.liasse
    spoil_key
    Api.transmit(S.admin, filing.id).error_keys.should eq(["teledec.errors.credentials.unreadable"])
    Api.filing(S.admin, filing.id).status.should eq("prepared")
  end

  it "ne laisse pas une transmission écraser une préparation faite pendant l'envoi" do
    S.books
    sale
    S.connect
    transport = ConcurrentPreparation.new
    with_transport(transport) do
      filing = S.liasse
      transport.during_submit = -> do
        sale("500")
        S.liasse
        nil
      end
      Api.transmit(S.admin, filing.id).error_keys.should eq(["teledec.errors.filing.concurrent"])
      after = Api.filing(S.admin, filing.id)
      after.status.should eq("prepared")
      after.fingerprint.should_not eq(filing.fingerprint)
      Api.events(S.admin, filing.id).map(&.status).should eq(%w[prepared prepared error])
      Api.events(S.admin, filing.id).last.detail.should contain("TD-000001")
    end
  end

  it "ne rend l'identifiant de l'API qu'aux titulaires des paramètres" do
    S.books
    S.connect
    Api.settings(S.admin).login.should eq(Teledec::SimulatedTeledec::LOGIN)
    reader = Api.settings(S.admin([Api::READ]))
    reader.login.should eq("")
    reader.key_stored.should be_true
  end

  it "rend une vue résumée pour la liste des dépôts" do
    S.books
    sale
    filing = S.liasse
    summary = Api.filings(S.admin, S.fiscal_year_id).first
    summary.should be_a(Api::FilingSummaryView)
    summary.id.should eq(filing.id)
    summary.status.should eq("prepared")
    summary.ready?.should eq(filing.ready?)
  end

  it "borne l'année de la DAS2" do
    S.books
    [0, 1999, 2101, 99_999].each do |year|
      Api.prepare(S.admin, Api::PrepareInput.new(kind: "das2", year: year)).error_keys.should eq(["teledec.errors.year.invalid"])
    end
  end
end
