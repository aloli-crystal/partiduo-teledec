# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Teledec::SpecSupport
private alias Api = Teledec::Api
private alias Acc = Partiduo::Api::Accounting
private alias Books = PartiduoUi::Books
private alias Formats = Teledec::Remote::Formats

private def sale(amount : String = "1000", day : String = "2026-03-10") : Nil
  Books.sale(Books.card("CUSTOMER", "Client #{amount}").code, amount, day)
  nil
end

private def march_ca3 : Acc::VatReturnView
  sale
  created = Acc.create_vat_return(S::SYSTEM, Acc::VatReturnInput.new(form: "fr_ca3", year: 2026, periodicity: "month", number: 3)).value!
  Acc.close_vat_return(S::SYSTEM, (created.id || raise("déclaration sans identifiant")), nil).value!
end

private def credentials(env : String = "sandbox") : Teledec::Credentials
  Teledec::Credentials.new(Teledec::SimulatedTeledec::LOGIN, Teledec::SimulatedTeledec::API_KEY, env,
    Teledec::SimulatedTeledec::EMAIL, Teledec::SimulatedTeledec::SIRET)
end

# Dernière requête reçue par le TELEDEC simulé pour un chemin.
private def last_request(path : String) : Teledec::Remote::Request
  S.teledec.requests.reverse.find! { |request| request.path == path }
end

describe "Adaptateur de l'API partenaire de TELEDEC (contre le TELEDEC simulé)" do
  it "obtient un jeton client_credentials, le garde en cache et le renouvelle sur un 401" do
    S.books
    sale
    S.connect
    S.teledec.token_requests.should eq(1) # vérification des identifiants
    token = last_request("/oauth2/token")
    token.headers["Authorization"].should start_with("Basic ")
    params = URI::Params.parse(token.body)
    params["grant_type"].should eq("client_credentials")
    params["scope"].split(' ').should contain("stage/liasse")
    params["scope"].split(' ').all?(&.starts_with?("stage/")).should be_true
    filing = S.liasse
    Api.transmit(S.admin, filing.id).value!
    Api.refresh(S.admin, filing.id).value!
    S.teledec.token_requests.should eq(1) # jeton gardé en cache
    S.teledec.expire_tokens!
    Api.refresh(S.admin, filing.id).value!.remote_status.should eq("notcompleted")
    S.teledec.token_requests.should eq(2) # 401 : nouveau jeton, appel rejoué
    last_request("/service/declaration-status").headers["Authorization"].should start_with("Bearer sim-2-")
  end

  it "vise l'environnement de production avec les scopes prod/" do
    S.books
    transport = S.teledec
    transport.check(credentials("production"))
    URI::Params.parse(last_request("/oauth2/token").body)["scope"].split(' ').all?(&.starts_with?("prod/")).should be_true
    expect_raises(Teledec::TransportError, "teledec.errors.transport.credentials") do
      transport.check(Teledec::Credentials.new("inconnu", "faux", "sandbox"))
    end
  end

  it "envoie la liasse par l'API Balance : identification, balance à huit colonnes, URL rendue" do
    S.books
    sale
    S.connect
    filing = S.liasse
    sent = Api.transmit(S.admin, filing.id).value!
    sent.remote_url.should start_with("https://stage.teledec.fr/liasse/")
    body = last_request("/service/liasse").body
    lines = body.lines
    lines.should contain("#SOURCE PARTIDUO")
    lines.should contain("#EMAIL #{Teledec::SimulatedTeledec::EMAIL}")
    lines.should contain("#SIRET #{Teledec::SimulatedTeledec::SIRET}")
    lines.should contain("#CATEGORIE-FISCALE BIC-IS")
    lines.should contain("#REEL-NORMAL-OU-SIMPLIFIE SIMPLIFIE")
    lines.should contain("#EXERCICE-DATE-DEBUT 20260101")
    lines.should contain("#EXERCICE-DATE-FIN 20261231")
    lines.should contain("#REFERENCE partiduo-#{filing.id}-1-#{filing.fingerprint[0, 16]}")
    lines.should contain("706;Prestations de services;0;0;0.00;1000.00;0.00;1000.00")
    lines.reject(&.starts_with?('#')).all? { |line| line.split(';').size == 8 }.should be_true
    last_request("/service/liasse").headers["Content-Type"].should start_with("text/plain")
  end

  it "traduit les refus de la liasse : source inconnue, SIRET absent, compte inconnu" do
    S.books
    sale
    S.connect
    filing = S.liasse
    S.teledec.source = "INCONNUE"
    Api.transmit(S.admin, filing.id).error_keys.should eq(["teledec.errors.transport.source"])
    S.teledec.source = "PARTIDUO"
    Api.save_credentials(S::SYSTEM, Api::CredentialsInput.new(Teledec::SimulatedTeledec::LOGIN, "",
      email: Teledec::SimulatedTeledec::EMAIL)).value!
    Api.transmit(S.admin, filing.id).error_keys.should eq(["teledec.errors.transport.siret"])
    S.connect
    Api.transmit(S.admin, filing.id).value!
    Api.save_credentials(S::SYSTEM, Api::CredentialsInput.new(Teledec::SimulatedTeledec::LOGIN, "",
      email: "autre@exemple.test", siret: Teledec::SimulatedTeledec::SIRET)).value!
    Api.refresh(S.admin, filing.id).error_keys.should eq(["teledec.errors.transport.account"])
  end

  it "envoie la CA3 en marque blanche avec les codes du formulaire 3310CA3, puis suit l'accusé" do
    S.books
    S.connect
    filing = S.prepare("vat_ca3", vat_return_id: march_ca3.id)
    sent = Api.transmit(S.admin, filing.id, "https://dossier.exemple.fr").value!
    sent.remote_id.should eq("3310CA3:732829320:2026-03-31:2026-04-19")
    sent.remote_url.should start_with("https://stage.teledec.fr/service/declaration/")
    sent.remote_status.should eq("readytobesent")
    document = JSON.parse(last_request("/service/declaration-marque-blanche").body)
    document["auth"]["email"].as_s.should eq(Teledec::SimulatedTeledec::EMAIL)
    document["auth"]["retournerLien"].as_bool.should be_true
    document["auth"]["url"].as_s.should start_with("https://dossier.exemple.fr/hooks/TELEDEC/callback?token=")
    document["auth"]["timestamp"].as_s.should match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\z/)
    document["identity"]["siret"].as_s.should eq(Teledec::SimulatedTeledec::SIRET)
    document["identity"]["regimeFiscalTVA"].as_s.should eq("Normal")
    document["period"]["begin"].as_s.should eq("2026-03-01")
    document["period"]["end"].as_s.should eq("2026-03-31")
    document["period"]["echeance"].as_s.should eq("2026-04-19")
    document["period"]["millesime"].as_i.should eq(2026)
    document["period"]["montant"].as_i.should eq(200)
    boxes = document["3310CA3"].as_h
    boxes["CA"].as_i.should eq(1000) # ligne A1
    boxes["FP"].as_i.should eq(1000) # ligne 08, base
    boxes["GP"].as_i.should eq(200)  # ligne 08, taxe
    boxes["GH"].as_i.should eq(200)  # ligne 16
    boxes["KA"].as_i.should eq(200)  # ligne 28
    boxes["KE"].as_i.should eq(200)  # ligne 32
    Api.refresh(S.admin, filing.id).value!.remote_status.should eq("readytobesent")
    last_request("/service/declaration-status").query_params["date_echeance"].should eq("2026-04-19")
    S.teledec.acknowledge(sent.remote_id)
    Api.refresh(S.admin, filing.id).value!.status.should eq("acknowledged")
  end

  it "bloque une CA3 dont une case n'a pas de code chez TELEDEC" do
    Formats.unmapped("vat_ca3", {"14.base" => "100", "08.base" => "10", "15" => "0"}, 2026).should eq(["14.base"])
    Formats.unmapped("vat_ca12", {"A1" => "100", "08.base" => "10", "B2" => "5"}, 2026).should eq(["B2"])
    Formats.unmapped("das2", {"x" => "1"}, 2026).should be_empty
  end

  it "met la DAS2 et les relevés d'IS aux codes de leurs formulaires" do
    S.books
    S.connect
    lawyer = S.supplier("Cabinet Durand")
    S.fees(lawyer, "1010", "2026-02-10")
    das2 = S.prepare("das2", year: 2026)
    Api.transmit(S.admin, das2.id).value!.remote_id.should eq("DAS2:732829320:2026-12-31")
    block = JSON.parse(last_request("/service/declaration-marque-blanche").body)["DAS2"]
    beneficiary = block["repetitionDAS2TV"][0]
    beneficiary["AF_3036_1"].as_s.should eq("Cabinet Durand")
    beneficiary["AF_3039_1"].as_s.should eq(S::SIRET)
    beneficiary["CA"].as_s.should eq("H")
    beneficiary["BA"].as_i.should eq(1212)
    beneficiary["AG_3251_1"].as_s.should eq("69003")
    block["repetitionDAS2TotauxSommesVersees"][0]["TA"].as_i.should eq(1212)

    advance = S.prepare("is_2571", fiscal_year_id: S.fiscal_year_id, number: 2, amount: BigDecimal.new(2500))
    Api.transmit(S.admin, advance.id).value!.remote_id.should eq("2571:732829320:2026-12-31:2026-06-15")
    document = JSON.parse(last_request("/service/declaration-marque-blanche").body)
    document["2571"]["CA"].as_i.should eq(2500)
    document["period"]["echeance"].as_s.should eq("2026-06-15")

    solde = S.prepare("is_2572", fiscal_year_id: S.fiscal_year_id, amount: BigDecimal.new(9000))
    Api.transmit(S.admin, solde.id).value!
    block = JSON.parse(last_request("/service/declaration-marque-blanche").body)["2572"]
    block["GE"].as_i.should eq(9000)
    block["RT"].as_i.should eq(2500)
    block["PN"].as_i.should eq(6500)
    block["CA"].as_i.should eq(6500)
  end

  it "refuse le dépôt au greffe, que l'API ne propose pas" do
    S.books
    sale
    S.connect
    Api.update_settings(S::SYSTEM, Api::SettingsInput.new("is_rsi", "ca3_monthly", greffe: true)).value!
    filing = S.prepare("greffe", fiscal_year_id: S.fiscal_year_id)
    Api.transmit(S.admin, filing.id).error_keys.should eq(["teledec.errors.transport.unsupported"])
  end

  it "note le rejet avec les erreurs de la DGFiP, et lit les comptes-rendus à défaut du suivi" do
    S.books
    sale
    S.connect
    filing = S.liasse
    Api.transmit(S.admin, filing.id).value!
    S.teledec.reject_with_errors(S::LIASSE_ID, [{"formulaire" => "2065", "champ" => "AA", "champLibelle" => "SIREN",
                                                 "champValeur" => "732829320", "code" => "E102", "libelle" => "SIREN inconnu"}])
    S.teledec.server.reports_in_status = false
    rejected = Api.refresh(S.admin, filing.id).value!
    rejected.status.should eq("rejected")
    rejected.rejection_reason.should eq("2065 AA (SIREN) = 732829320 : E102 SIREN inconnu")
    rejected.remote_status.should eq("erreur")
    last_request("/service/recuperation-liste-compterendus").query_params["dateFin"].should eq("2026-12-31")
  end

  it "associe les statuts de TELEDEC aux états d'un dépôt" do
    {"NotCompleted" => "pending", "readyToBeSent" => "pending", "Sent" => "pending", "OK" => "acknowledged",
     "Accepted" => "acknowledged", "CompleteWithWarnings" => "acknowledged", "CompleteWithErrors" => "rejected",
     "ERREUR" => "rejected", "Rejected" => "rejected", "inattendu" => "pending"}.each do |status, state|
      Formats.state(status).should eq(state)
    end
    body = <<-JSON
      {"declarationId": 12, "reference": "r", "status": "OK", "formulairesStatus": "Rejected",
       "erreurCode": "E1", "erreurLibelle": "Montant incohérent", "dateHeureDGFiP": "2027-05-10T10:30:00"}
      JSON
    report = Formats.report(JSON.parse(body))
    report.state.should eq("rejected")
    report.reason.should eq("E1 Montant incohérent")
    report.declaration_id.should eq("12")
    report.at.should eq(Time.utc(2027, 5, 10, 8, 30))
  end

  it "prend le compte-rendu le plus récent, et le relève par la liste quand le suivi ne le joint pas" do
    older = Formats::Report.new("1", "r", "ERREUR", "ancien", nil, Time.utc(2027, 1, 1), "liasse")
    newer = Formats::Report.new("2", "r", "OK", "", nil, Time.utc(2027, 2, 1), "liasse")
    Formats.latest([newer, older]).should eq(newer)
    Formats.latest([] of Formats::Report).should be_nil
    S.books
    S.teledec.check(credentials)
    Formats::Key.parse("liasse:732829320:2026-12-31").to_s.should eq("liasse:732829320:2026-12-31")
    Formats::Key.parse("n'importe quoi").should be_nil
    S.teledec.reports(credentials, Formats::Key.new("liasse", "732829320", "2026-12-31")).should be_empty
  end

  it "ne met ni le secret ni le jeton dans les erreurs" do
    S.books
    error = expect_raises(Teledec::TransportError) do
      S.teledec.check(Teledec::Credentials.new(Teledec::SimulatedTeledec::LOGIN, "secret-tres-long", "sandbox"))
    end
    error.message.to_s.should_not contain("secret-tres-long")
    error.key.should eq("teledec.errors.transport.credentials")
  end
end
