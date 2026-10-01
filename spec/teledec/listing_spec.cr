# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Teledec::SpecSupport
private alias Api = Teledec::Api
private alias Formats = Teledec::Remote::Formats
private alias Books = PartiduoUi::Books

private DAS2_ID = "DAS2:732829320:2026-12-31"

private def transmitted_das2 : Api::FilingView
  S.books
  S.connect
  S.fees(S.supplier("Cabinet Durand"), "1500")
  das2 = S.prepare("das2", year: 2026)
  Api.transmit(S.admin, das2.id).value!
end

private def paths : Array(String)
  S.teledec.requests.map(&.path)
end

private def listed(type : String, date_fin : String, id : String = "1", status : String = "Created") : Formats::Listed
  Formats::Listed.new(id, type, "#{date_fin[0, 4]}-01-01", date_fin, status, "")
end

describe "Suivi par la liste des déclarations de TELEDEC (D-TDC12-001 à 003)" do
  it "suit la DAS2 sous la liasse de son année civile, jamais sous DAS2" do
    Formats.tracking(Formats::Key.new("DAS2", "732829320", "2026-12-31"))
      .should eq(Formats::Key.new("liasse", "732829320", "2026-12-31"))
    key = Formats::Key.new("3310CA3", "732829320", "2026-03-31", "2026-04-19")
    Formats.tracking(key).should eq(key)
    das2 = transmitted_das2
    Api.refresh(S.admin, das2.id).value!.remote_status.should eq("readytobesent")
    tracked = S.teledec.requests.select(&.path.==("/service/declaration-status")).map(&.query_params)
    tracked.map { |params| {params["formulaire"], params["date_fin"]} }.uniq!.should eq([{"liasse", "2026-12-31"}])
    paths.should_not contain("/service/declarations")
  end

  it "demande le droit liste-declarations, facultatif : sans lui, le dépôt introuvable reste en attente" do
    Teledec::HttpTransport::OPTIONAL_SCOPES.should contain("liste-declarations")
    Teledec::Transports.current = Teledec::SimulatedTeledec.new.tap(&.refused_scopes.add("liste-declarations"))
    S.teledec.hidden_until_opened << "DAS2"
    das2 = transmitted_das2
    refreshed = Api.refresh(S.admin, das2.id).value!
    {refreshed.status, refreshed.remote_status, refreshed.last_error}.should eq({"transmitted", "notfound", ""})
    paths.should_not contain("/service/declarations")
    # Demandé d'abord, refusé (`invalid_scope`), puis jeton sans lui.
    scopes = S.teledec.requests.select(&.url.==(Teledec::HttpTransport::AUTH_URL))
      .map { |request| URI::Params.parse(request.body)["scope"].split(' ') }
    scopes.first.should contain("stage/liste-declarations")
    scopes.last.should_not contain("stage/liste-declarations")
  end

  it "lit dans la liste l'état d'une DAS2 que le suivi ne trouve pas : Created, son identifiant, jamais ses liens" do
    S.teledec.hidden_until_opened << "DAS2"
    das2 = transmitted_das2
    refreshed = Api.refresh(S.admin, das2.id).value!
    {refreshed.status, refreshed.remote_status}.should eq({"transmitted", "created"})
    deposit = S.teledec.deposits[DAS2_ID]
    refreshed.declaration_id.should eq(deposit.declaration_id.to_s)
    listing = S.teledec.requests.find!(&.path.==("/service/declarations")).query_params
    {listing["siren"], listing["email"]}.should eq({"732829320", Teledec::SimulatedTeledec::ACCOUNT})
    Formats.state("Created").should eq("pending")
    Api::AWAITING_STATUSES.should eq(%w[notfound created])
    # Aucun lien temporaire de la liste n'est gardé (dépôt, historique).
    stored = Marten::DB::Connection.default.open do |db|
      db.query_one("SELECT concat_ws(' ', remote_url, remote_status, declaration_id, last_error) FROM teledec_filing WHERE id = $1",
        das2.id, as: String) +
        db.query_all("SELECT detail FROM teledec_filing_event WHERE filing_id = $1", das2.id, as: String).join(' ')
    end
    stored.should_not contain("eyJ")
    stored.should_not contain("declarationPdfNom")
    # Lien ouvert : le suivi (sous `liasse`) la trouve.
    S.teledec.open_link(DAS2_ID)
    Api.refresh(S.admin, das2.id).value!.remote_status.should eq("readytobesent")
  end

  it "prend l'accusé d'un dépôt que le suivi ne trouve jamais, accepté d'après la liste" do
    S.teledec.untracked << "DAS2"
    das2 = transmitted_das2
    Api.refresh(S.admin, das2.id).value!.remote_status.should eq("readytobesent")
    S.teledec.acknowledge(DAS2_ID)
    acknowledged = Api.refresh(S.admin, das2.id).value!
    {acknowledged.status, acknowledged.remote_status}.should eq({"acknowledged", "accepted"})
    acknowledged.receipt_attachment_id.should_not be_nil
    acknowledged.declaration_id.should eq(S.teledec.deposits[DAS2_ID].declaration_id.to_s)
  end

  it "garde en attente une liasse que ni le suivi ni la liste ne trouvent, puis la suit une fois son lien ouvert" do
    S.books
    Books.sale(Books.card("CUSTOMER", "Atelier Morel").code, "1000")
    S.connect
    S.teledec.hidden_until_opened << "liasse"
    filing = Api.transmit(S.admin, S.liasse.id).value!
    Api.refresh(S.admin, filing.id).value!.remote_status.should eq("notfound")
    paths.should contain("/service/declarations")
    S.teledec.open_link(S::LIASSE_ID)
    Api.refresh(S.admin, filing.id).value!.remote_status.should eq("notcompleted")
  end

  it "retrouve une déclaration listée par son type et sa date de fin, jamais ambiguë" do
    das2 = Formats::Key.new("DAS2", "732829320", "2026-12-31")
    found = Formats.find_listed([listed("TVA", "2026-12-31"), listed("Liasse", "2026-12-31", "7")], das2)
    found.try(&.id).should eq("7")
    Formats.find_listed([listed("Liasse", "2025-12-31")], das2).should be_nil
    advance = Formats::Key.new("2571", "732829320", "2026-12-31", "2026-06-15")
    Formats.find_listed([listed("Paiement", "2026-12-31", "1"), listed("Paiement", "2026-12-31", "2")], advance).should be_nil
    Formats.find_listed([listed("Paiement", "2026-12-31", "1")], advance).try(&.id).should eq("1")
    Formats.find_listed([listed("Liasse", "2026-12-31")], Formats::Key.new("inconnu", "732829320", "2026-12-31")).should be_nil
    body = <<-JSON
      {"id": 286182, "declarationType": "Liasse", "dateDebut": "2025-01-01", "dateFin": "2025-12-31",
       "status": "Created", "lienFichierEDI": "https://stage.teledec.fr/service/fichierEDI/eyJ"}
      JSON
    item = Formats.listed(JSON.parse(body))
    item.should eq(Formats::Listed.new("286182", "Liasse", "2025-01-01", "2025-12-31", "Created", ""))
    Formats.listed(JSON.parse("[]")).should be_nil
  end
end
