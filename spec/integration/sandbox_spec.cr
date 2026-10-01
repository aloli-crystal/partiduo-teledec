# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Suite d'intégration contre le stage de TELEDEC : voir l'en-tête de
# `spec/support/sandbox.cr` (réglages, rappels, confidentialité de la
# sortie), où vivent ses outils, partagés avec la suite d'exploration
# (`spec/integration/exploration_spec.cr`).

private alias Sandbox = Teledec::SandboxSpec

describe "Stage de TELEDEC (intégration, optionnelle)" do
  if Sandbox.values
    it "vise le stage, jamais la production" do
      Sandbox.credentials.env.should eq("sandbox")
      Teledec::HttpTransport::API_URLS["sandbox"].should eq("https://stage.teledec.fr")
    end

    it "obtient un jeton, et refuse un secret faux" do
      Sandbox.require_stage!
      transport = Sandbox.transport
      transport.check(Sandbox.credentials)
      error = expect_raises(Teledec::TransportError) do
        transport.check(Sandbox.credentials("secret-faux"))
      end
      error.key.should eq("teledec.errors.transport.credentials")
    end

    it "crée l'entreprise de test et la rattache au compte" do
      Sandbox.require_stage!
      password = Crypto::Bcrypt::Password.create(Random::Secure.hex(16), cost: 12).to_s
      account = Sandbox.account!
      answer = Sandbox.transport.create_company(Sandbox.credentials, Sandbox.company_identity, password, account)
      fail "création de l'entreprise : réponse sans l'adresse du compte (#{Sandbox.scrub(answer)[0, 200]})" unless answer.includes?(account)
    end

    it "envoie la liasse d'une balance de démonstration (URL rendue, source `API`)" do
      Sandbox.require_stage!
      Sandbox.account!
      transport = Sandbox.transport
      submission = Sandbox.submission(Sandbox.liasse_payload)
      submitted = transport.submit(Sandbox.credentials, submission)
      Sandbox.expect_link!(submitted, "https://stage.teledec.fr", "Lien")
      submitted.remote_id.should eq("liasse:#{Sandbox::SIREN}:2025-12-31")
      status = Sandbox.status!(transport, Sandbox.credentials, "liasse:#{Sandbox::SIREN}:2025-12-31", "Liasse")
      status.state.should eq("pending")
    end

    it "dépose une CA3 en marque blanche (lien rendu, sans millésime), puis en relève l'état" do
      # TVA : aucun millésime, TELEDEC le déduit de `period.end` (D-TDC9-003).
      document = JSON.parse(Teledec::Remote::Formats.white_label(Sandbox.ca3_payload, Sandbox.submission(Sandbox.ca3_payload, due_on: "2026-09-19"),
        Teledec::Credentials.new("x", "y", "sandbox", Sandbox::EMAIL, Sandbox::SIRET), Time.utc, "compte@exemple.org"))
      document["period"]["millesime"]?.should be_nil
      Sandbox.require_stage!
      Sandbox.account!
      transport = Sandbox.transport
      submission = Sandbox.submission(Sandbox.ca3_payload, due_on: "2026-09-19")
      submitted = transport.submit(Sandbox.credentials, submission)
      submitted.remote_id.should eq("3310CA3:#{Sandbox::SIREN}:2026-08-31:2026-09-19")
      Sandbox.expect_link!(submitted, "https://stage.teledec.fr/", "Lien")
      status = Sandbox.status!(transport, Sandbox.credentials, submitted.remote_id, "CA3")
      status.state.should eq("pending")
      status.remote_status.should eq("readytobesent")
    end

    it "dépose une DAS2 seule, au millésime 2026, en marque blanche (société à deux natures, personne physique) sans erreur bloquante de TELEDEC" do
      due_on = Teledec::Calendar.das2(2025).to_s("%F")
      # Document vérifié avant tout appel : DAS2 seule, millésime de la
      # campagne 2026 (le stage refusait le millésime 2025, D-TDC6-001).
      document = JSON.parse(Teledec::Remote::Formats.white_label(Sandbox.das2_payload, Sandbox.submission(Sandbox.das2_payload, due_on: due_on),
        Teledec::Credentials.new("x", "y", "sandbox", Sandbox::EMAIL, Sandbox::SIRET), Time.utc, "compte@exemple.org"))
      (document.as_h.keys - %w[auth identity period]).should eq(["DAS2"])
      document["period"]["millesime"].as_i.should eq(2026)
      document["identity"]["fullRegimeFiscal"]?.should be_nil
      Sandbox.require_stage!
      Sandbox.account!
      recorder = Sandbox::Recorder.new
      transport = Sandbox.transport(recorder)
      credentials = Sandbox.credentials
      submitted = Sandbox.deposit!(transport, credentials, Sandbox.submission(Sandbox.das2_payload, due_on: due_on), "DAS2")
      Sandbox.expect_link!(submitted, "https://stage.teledec.fr/", "Lien")
      submitted.remote_id.should eq("DAS2:#{Sandbox::SIREN}:2025-12-31")
      status = Sandbox.settled_status!(recorder, transport, credentials, submitted.remote_id, "DAS2")
      status.state.should eq("pending")
      status.remote_status.should_not be_empty
    end

    it "dépose un relevé d'acompte d'IS 2571 en marque blanche (entreprise de test à l'IS), lien et état" do
      Sandbox.require_stage!
      account = Sandbox.account!
      # Régime de l'entreprise de test réglé à l'IS (`ISRS`) avant le dépôt.
      Sandbox.transport.create_company(Sandbox.credentials, Sandbox.company_identity, Sandbox.password_hash, account)
      recorder = Sandbox::Recorder.new
      transport = Sandbox.transport(recorder)
      credentials = Sandbox.credentials(account_ready: true)
      due_on = Teledec::Calendar.corporate_tax_advances(Time.utc(2026, 1, 1), Time.utc(2026, 12, 31))[3].to_s("%F")
      submission = Sandbox.submission(Sandbox.advance_payload, due_on: due_on, year_end: "2026-12-31")
      submitted = Sandbox.deposit!(transport, credentials, submission, "Relevé 2571")
      Sandbox.expect_link!(submitted, "https://stage.teledec.fr/", "Lien")
      submitted.remote_id.should eq("2571:#{Sandbox::SIREN}:2026-12-31:#{due_on}")
      status = Sandbox.settled_status!(recorder, transport, credentials, submitted.remote_id, "Relevé 2571")
      status.state.should eq("pending")
      status.remote_status.should_not be_empty
    end

    it "dépose la 2035 d'un libéral sans Comptabilité, sans balance (seconde entreprise de test, BNC)" do
      # Construite par l'extension dans la base de test, avant tout appel.
      payload = Sandbox.liberal_payload
      payload.forms.should eq(%w[2035])
      payload.balance.should be_nil
      payload.details["source"].should eq("liberal")
      # Corps vérifié avant tout appel (D-TDC7-001) : aucune section de
      # balance, section JSON documentée (plusieurs lignes, deux blocs).
      sections = Teledec::SpecSupport::LiasseBody.parse(Teledec::Remote::Formats.liasse(payload,
        Sandbox.submission(payload), Teledec::Credentials.new("x", "y", "sandbox", Sandbox::EMAIL, Sandbox::LIBERAL_SIRET),
        "API", false, "compte@exemple.org"))
      sections.balance.should be_empty
      (sections.json || "").lines.first?.should eq("{")
      sections.document.as_h.keys.sort!.should eq(%w[informations_supplementaires zones_formulaires])
      Sandbox.require_stage!
      Sandbox.account!(Sandbox::LIBERAL_SIREN).should_not eq(Sandbox.account!)
      recorder = Sandbox::Recorder.new
      transport = Sandbox.transport(recorder)
      credentials = Sandbox.credentials(siret: Sandbox::LIBERAL_SIRET)
      submitted = Sandbox.deposit!(transport, credentials, Sandbox.submission(payload), "Liasse 2035 sans balance",
        recorder)
      Sandbox.expect_link!(submitted, "https://stage.teledec.fr", "Lien")
      submitted.remote_id.should eq("liasse:#{Sandbox::LIBERAL_SIREN}:2025-12-31")
      # Compte de la seconde entreprise créé par l'adaptateur avant la
      # liasse (la liasse ne le crée pas, D-TDC5-002) : le suivi le trouve.
      Sandbox.status!(transport, credentials, submitted.remote_id, "Liasse 2035 sans balance").state.should eq("pending")
    end

    it "amorce le dépôt au greffe (nouvelle-declaration) et rend l'adresse de redirection, sans le finaliser" do
      # Corps vérifié avant tout appel : formulaire greffe, exercice 2025
      # (hypothèse D-TDC9-001, sur le modèle de la marque blanche).
      payload = Sandbox.greffe_payload
      body = JSON.parse(Teledec::Remote::Formats.greffe(payload, Sandbox.submission(payload),
        Teledec::Credentials.new("x", "y", "sandbox", Sandbox::EMAIL, Sandbox::SIRET), Time.utc, "compte@exemple.org"))
      body["formulaire"].as_s.should eq("greffe")
      body["period"]["end"].as_s.should eq("2025-12-31")
      Teledec::Config.greffe_eligible?(payload.identity.legal_form).should be_true
      Sandbox.require_stage!
      account = Sandbox.account!
      # Entreprise de test à l'IS (`ISRS`), forme SAS, avant l'amorce.
      Sandbox.transport.create_company(Sandbox.credentials, Sandbox.company_identity, Sandbox.password_hash, account)
      recorder = Sandbox::Recorder.new
      transport = Sandbox.transport(recorder)
      credentials = Sandbox.credentials(account_ready: true)
      submitted = begin
        transport.submit(credentials, Sandbox.submission(payload))
      rescue ex : Teledec::TransportError
        if ex.key == "teledec.errors.transport.scope"
          pending!("droit nouvelle-declaration absent du jeton du stage : à faire activer par TELEDEC")
        end
        route = recorder.last_path.try { |path| " (route #{path})" }
        fail "Amorce du greffe refusée#{route} : #{ex.key} — " \
             "#{Sandbox.scrub(ex.params.values.join(" ; ").presence || "sans message de TELEDEC")}"
      end
      # L'adresse (connexion automatique) n'est jamais affichée en entier ;
      # l'utilisateur l'ouvrirait dans un nouvel onglet pour finaliser.
      Sandbox.expect_link!(submitted, "https://stage.teledec.fr", "Adresse du greffe")
      submitted.remote_id.should eq("greffe:#{Sandbox::SIREN}:2025-12-31")
      submitted.remote_status.should eq("notcompleted")
    end

    it "reçoit, après l'envoi de la CA3 depuis son lien, un rappel authentifié accepté par la réception de l'extension ; un mauvais mot de passe est refusé" do
      public_url = Sandbox.setting("TELEDEC_CALLBACK_URL")
      password = Sandbox.setting("TELEDEC_CALLBACK_PASSWORD")
      unless public_url && password
        pending!("adresse publique des rappels non réglée (TELEDEC_CALLBACK_URL et TELEDEC_CALLBACK_PASSWORD)")
      end
      Sandbox.require_stage!
      Sandbox.account!
      Sandbox.with_callback_password(password) do
        target = Sandbox.callback_target(public_url) || fail "TELEDEC_CALLBACK_URL : adresse https attendue"
        # Extension active dans la base de test (sinon la réception répond 404).
        Teledec::SpecSupport.books
        receiver = begin
          Sandbox::CallbackReceiver.new(Sandbox.callback_port).start
        rescue ex : Socket::Error
          fail "port #{Sandbox.callback_port} indisponible (TELEDEC_CALLBACK_PORT) : #{ex.message}"
        end
        begin
          submission = Sandbox.submission(Sandbox.ca3_payload(7), due_on: "2026-08-19", callback_url: target)
          submitted = Sandbox.deposit!(Sandbox.transport, Sandbox.credentials, submission, "CA3 avec adresse de rappel")
          wait = Sandbox.callback_wait
          # TELEDEC rappelle à l'envoi, à l'acceptation et au rejet, jamais
          # au dépôt (D-TDC9-004) ; en marque blanche, l'envoi se fait
          # depuis le lien de la déclaration (aucune route d'envoi dans
          # l'API, D-TDC5-003).
          link_file = Sandbox.announce_send(submitted, wait, receiver.port)
          received = Sandbox.wait_callback(receiver, wait, submission.reference) ||
                     fail "aucun rappel de TELEDEC pour #{submitted.remote_id} en #{wait.total_seconds.to_i} s : TELEDEC " \
                          "ne rappelle qu'à l'envoi, à l'acceptation et au rejet, jamais au dépôt — la déclaration " \
                          "a-t-elle été envoyée depuis son lien (bouton « Envoyer ») ? Vérifier aussi le tunnel vers " \
                          "le port #{receiver.port}, ou allonger TELEDEC_CALLBACK_WAIT"
          if received.status != 200
            fail "rappel reçu mais refusé par la réception de l'extension (HTTP #{received.status}) : " \
                 "#{received.status == 401 ? "mot de passe du rappel différent de TELEDEC_CALLBACK_PASSWORD" : "corps illisible"}"
          end
          user = Sandbox.setting("TELEDEC_CALLBACK_USER") || "teledec"
          wrong = "Basic #{Base64.strict_encode("#{user}:#{password}-faux")}"
          receiver.dispatch(received.body, wrong).should eq(401)
          receiver.dispatch(received.body, nil).should eq(401)
          receiver.dispatch(received.body, "Basic #{Base64.strict_encode("#{user}:#{password}")}").should eq(200)
        ensure
          link_file.try { |path| File.delete?(path) }
          receiver.close
        end
      end
    end
  else
    pending "identifiants du stage absents (~/.config/partiduo/teledec-sandbox.env)"
  end
end

# Confidentialité de la sortie de la suite (hors ligne, toujours active) :
# ni jeton JWT, ni haché bcrypt dans un message ; lien de déclaration
# écrit dans un fichier lisible du seul utilisateur.
describe "Sortie de la suite du stage (expurgation)" do
  jwt = "eyJhbGciOiJIUzI1NiJ9.eyJlbWFpbCI6ImNvbXB0ZUBleGVtcGxlLm9yZyJ9.c2lnbmF0dXJlLWZpY3RpdmU"
  hash = "$2a$12$abcdefghijklmnopqrstuuABCDEFGHIJKLMNOPQRSTUVWXYZ01234"

  it "retire des messages les jetons JWT et les hachés bcrypt, en clair ou encodés dans une adresse" do
    text = "refus : https://stage.teledec.fr/service/declaration/#{jwt} ; mot de passe #{hash} ; " \
           "?p=%242b%2412%24abcdefghijklmnopqrstuv ; eyJhbGciOiJIUzI1NiJ9.eyJ4IjoxfQ"
    clean = Sandbox.scrub(text)
    {clean.includes?("eyJ"), clean.includes?("$2a$"), clean.includes?("%242b")}.should eq({false, false, false})
    clean.should start_with("refus : https://stage.teledec.fr/service/declaration/***")
  end

  it "n'affiche du lien que son début, et l'écrit en entier dans un fichier à droits 0600" do
    link = "https://stage.teledec.fr/service/declaration/#{jwt}"
    Sandbox.truncated(link).should eq("https://stage.teledec.fr/service/declaration/…")
    Sandbox.truncated(link).includes?("eyJ").should be_false
    path = Sandbox.write_link(link)
    begin
      (File.info(path).permissions.value & 0o777).should eq(0o600)
      File.read(path).should eq("#{link}\n")
    ensure
      File.delete?(path)
    end
  end
end
