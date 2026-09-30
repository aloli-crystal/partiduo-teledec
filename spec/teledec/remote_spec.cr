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
    lines.should contain("#SOURCE API")
    lines.should contain("#EMAIL #{Teledec::SimulatedTeledec::ACCOUNT}")
    lines.should contain("#MOT-DE-PASSE #{Teledec::Settings.current!.account_password_hash}")
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
    S.teledec.source = "API"
    Api.save_credentials(S::SYSTEM, Api::CredentialsInput.new(Teledec::SimulatedTeledec::LOGIN, "",
      email: Teledec::SimulatedTeledec::EMAIL)).value!
    Api.transmit(S.admin, filing.id).error_keys.should eq(["teledec.errors.transport.siret"])
    S.connect
    Api.transmit(S.admin, filing.id).value!
    # Autre domaine du partenaire : TELEDEC ne connaît pas ce compte.
    Teledec::Transports.current = Teledec::SimulatedTeledec.new(S.teledec.server, user_domain: "autre.test")
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
    # Compte de l'entreprise créé avant sa première déclaration en marque
    # blanche, dans le domaine du partenaire.
    company = JSON.parse(last_request("/service/creation-entreprise").body)
    company["auth"]["email"].as_s.should eq(Teledec::SimulatedTeledec::ACCOUNT)
    company["auth"]["password"].as_s.should start_with("$2a$12$")
    S.teledec.accounts.keys.should eq([Teledec::SimulatedTeledec::ACCOUNT])
    document["auth"]["email"].as_s.should eq(Teledec::SimulatedTeledec::ACCOUNT)
    document["identity"]["email"].as_s.should eq(Teledec::SimulatedTeledec::EMAIL)
    document["auth"]["retournerLien"].as_bool.should be_true
    document["auth"]["url"].as_s.should eq("https://dossier.exemple.fr/hooks/TELEDEC/callback")
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

  it "transmet les opérations au taux particulier de 2,10 % taux par taux, sans ligne 14" do
    S.books
    S.connect
    sale
    press = Acc::DocumentInput.new(ledger_id: Books.ledger("V01").id, date: Books.date("2026-03-12"),
      third_party: Books.card("CUSTOMER", "Kiosque Martin").code, label: "Presse",
      lines: [Acc::DocumentLineInput.new(amount: Books.d("500"), account: "706", vat_rate: "TP021")])
    Acc.post_sale(S::SYSTEM, press).value!
    created = Acc.create_vat_return(S::SYSTEM, Acc::VatReturnInput.new(form: "fr_ca3", year: 2026, periodicity: "month", number: 3)).value!
    closed = Acc.close_vat_return(S::SYSTEM, (created.id || raise("déclaration sans identifiant")), nil).value!
    closed.annex_lines.map(&.vat_number).should eq(["TP021"])
    filing = S.prepare("vat_ca3", vat_return_id: closed.id)
    filing.controls.map(&.key).should_not contain("teledec.controls.box_unmapped")
    Api.transmit(S.admin, filing.id).value!
    boxes = JSON.parse(last_request("/service/declaration-marque-blanche").body)["3310CA3"].as_h
    {boxes["MF"].as_i, boxes["ME"].as_i}.should eq({500, 11}) # 2,10 % de 500 = 10,50
    boxes["GH"].as_i.should eq(211)                           # 200 + 11
  end

  it "bloque une CA3 dont une case n'a pas de code chez TELEDEC" do
    Formats.unmapped("vat_ca3", {"14.base" => "100", "08.base" => "10", "15" => "0"}, 2026).should eq(["14.base"])
    Formats.unmapped("vat_ca12", {"A1" => "100", "08.base" => "10", "B2" => "5", "29" => "3"}, 2026).should eq(["29"])
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
    amounts = beneficiary["repetitionDAS2MontantSommesVersees"][0]
    amounts["CA"].as_s.should eq("H")
    amounts["BA"].as_i.should eq(1212)
    beneficiary["AG_3251_1"].as_s.should eq("69003")
    block["repetitionDAS2TotauxSommesVersees"][0]["TA"].as_i.should eq(1212)
    # Jointe au formulaire principal du régime (IS simplifié : 2065), vide.
    JSON.parse(last_request("/service/declaration-marque-blanche").body)["2065"].as_h.should be_empty

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

    # Rappels et comptes-rendus : DAS2 de type `Part`, relevés d'IS de type
    # `Paiement` (réponses de TELEDEC du 29 septembre 2026).
    S.teledec.acknowledge("DAS2:732829320:2026-12-31")
    (S.teledec.deposits["DAS2:732829320:2026-12-31"].report || raise "compte-rendu absent")["declarationType"].as_s.should eq("Part")
    Api.refresh(S.admin, das2.id).value!.status.should eq("acknowledged")
    S.teledec.acknowledge("2571:732829320:2026-12-31:2026-06-15")
    Api.refresh(S.admin, advance.id).value!.status.should eq("acknowledged")
  end

  it "refuse, comme le stage, un dépôt en marque blanche sans formulaire principal du régime (DAS2 seule)" do
    S.books
    server = S.teledec.server
    basic = Base64.strict_encode("#{Teledec::SimulatedTeledec::LOGIN}:#{Teledec::SimulatedTeledec::API_KEY}")
    token = server.call(Teledec::Remote::Request.new("POST", Teledec::HttpTransport::AUTH_URL,
      HTTP::Headers{"Authorization" => "Basic #{basic}"}, "grant_type=client_credentials&scope=stage/marque-blanche"))
    bearer = HTTP::Headers{"Authorization" => "Bearer #{JSON.parse(token.body)["access_token"].as_s}"}
    stamp = Formats.paris(Time.utc).to_s("%Y-%m-%dT%H:%M:%S")
    das2 = {"repetitionDAS2TV" => [{"AF_3036_1" => "Cabinet Durand",
                                    "repetitionDAS2MontantSommesVersees" => [{"CA" => "H", "BA" => 1212}]}]}
    document = {"auth" => {"email" => Teledec::SimulatedTeledec::ACCOUNT, "timestamp" => stamp},
                "identity" => {"siret" => Teledec::SimulatedTeledec::SIRET},
                "period" => {"begin" => "2026-01-01", "end" => "2026-12-31"}, "DAS2" => das2}
    url = "https://stage.teledec.fr/service/declaration-marque-blanche"
    alone = server.call(Teledec::Remote::Request.new("POST", url, bearer, document.to_json))
    alone.status.should eq(400)
    JSON.parse(alone.body)["message"].as_s.should eq(
      "aucun formulaire de TVA ou de paiement ou de liasse n'a été trouvé dans le message envoyé depuis votre " \
      "logiciel de comptabilité. Un des formulaires principaux permettant l'identification du régime de " \
      "l'entreprise n'est pas présent, veuillez en saisir un dans votre payload. ISRN : 3310CA3, 3514, 3519…")
    S.teledec.deposits.should be_empty
    joined = document.merge({"2065" => {} of String => String})
    server.call(Teledec::Remote::Request.new("POST", url, bearer, joined.to_json)).status.should eq(200)
    S.teledec.deposits.keys.should eq(["DAS2:732829320:2026-12-31"])
  end

  it "garde en attente un dépôt que les contrôles de TELEDEC bloquent avant l'envoi" do
    S.books
    sale
    S.connect
    filing = Api.transmit(S.admin, S.liasse.id).value!
    S.teledec.deposits[S::LIASSE_ID].status = "CompleteWithErrors"
    checked = Api.refresh(S.admin, filing.id).value!
    {checked.status, checked.remote_status}.should eq({"transmitted", "completewitherrors"})
    I18n.t("teledec.remote_statuses.completewitherrors").should contain("Contrôles de TELEDEC")
  end

  it "refuse le dépôt au greffe, qui ne passe pas par l'API (redirection en marque blanche)" do
    S.books
    sale
    S.connect
    Api.update_settings(S::SYSTEM, Api::SettingsInput.new("is_rsi", "ca3_monthly", greffe: true)).value!
    filing = S.prepare("greffe", fiscal_year_id: S.fiscal_year_id)
    Api.transmit(S.admin, filing.id).error_keys.should eq(["teledec.errors.transport.greffe"])
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
     "Accepted" => "acknowledged", "CompleteWithWarnings" => "pending", "CompleteWithErrors" => "pending",
     "ERREUR" => "rejected", "Rejected" => "rejected", "inattendu" => "pending"}.each do |status, state|
      Formats.state(status).should eq(state)
    end
    body = <<-JSON
      {"declarationId": 12, "reference": "r", "status": "ERREUR", "formulairesStatus": "Rejected",
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
