# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Teledec::SpecSupport
private alias Api = Teledec::Api
private alias Books = PartiduoUi::Books
private alias Sim = Teledec::SimulatedTeledec

private def sale : Nil
  Books.sale(Books.card("CUSTOMER", "Atelier Morel").code, "1000")
  nil
end

private def credentials_input(email : String = Sim::EMAIL, siret : String = Sim::SIRET, key : String = Sim::API_KEY) : Api::CredentialsInput
  Api::CredentialsInput.new(Sim::LOGIN, key, email: email, siret: siret)
end

# En-tête `Authorization` d'un rappel de TELEDEC : mot de passe des rappels
# du partenaire (réglage de l'instance, D-TDC3-006).
private def token(password : String = ENV["PARTIDUO_TELEDEC_CALLBACK_PASSWORD"]) : String
  "Basic #{Base64.strict_encode("teledec:#{password}")}"
end

private def transmitted_liasse : Api::FilingView
  S.books
  sale
  S.connect
  Api.transmit(S.admin, S.liasse.id).value!
end

private def sql_error(sql : String, *args) : String?
  Marten::DB::Connection.default.open(&.exec(sql, *args))
  nil
rescue ex : PQ::PQError
  ex.message
end

describe "Contrat de l'adaptateur réel de TELEDEC (compte, SIRET, rappels)" do
  it "contrôle l'email de contact et le SIRET, retire les espaces du SIRET" do
    S.books
    refused = Api.save_credentials(S::SYSTEM, credentials_input(email: "pas-un-email", siret: "1234"))
    refused.error_keys.should eq(["teledec.errors.credentials.email", "teledec.errors.credentials.siret"])
    Api.save_credentials(S::SYSTEM, credentials_input(email: "a@b", siret: "")).error_keys
      .should eq(["teledec.errors.credentials.email"])
    Api.save_credentials(S::SYSTEM, credentials_input(email: "#{"x" * 251}@b.fr")).error_keys
      .should eq(["teledec.errors.credentials.email"])
    Api.save_credentials(S::SYSTEM, credentials_input(siret: "7328293200007A")).error_keys
      .should eq(["teledec.errors.credentials.siret"])
    S.teledec.token_requests.should eq(0) # rien n'est vérifié chez TELEDEC tant que la saisie est invalide
    # SIRET d'un autre SIREN que celui de la société : refusé.
    other = Api.save_credentials(S::SYSTEM, credentials_input(siret: "40483304800006"))
    other.error_keys.should eq(["teledec.errors.credentials.siret_siren"])
    other.errors.first.params["siren"].should eq("732829320")
    saved = Api.save_credentials(S::SYSTEM, credentials_input(email: "  #{Sim::EMAIL} ", siret: "732 829 320 00074")).value!
    saved.email.should eq(Sim::EMAIL)
    saved.siret.should eq("73282932000074")
  end

  it "authentifie les rappels par le mot de passe du partenaire, réglé dans l'instance" do
    S.books
    S.connect
    view = Api.settings(S.admin)
    {view.callback_path, view.callback_password, view.account_email}
      .should eq({Api::CALLBACK_PATH, true, Sim::ACCOUNT})
    Api.callback(token, "{}").should eq("ignored")
    Api.callback(token("faux"), "{}").should eq("unauthorized")
    Api.callback("Bearer #{ENV["PARTIDUO_TELEDEC_CALLBACK_PASSWORD"]}", "{}").should eq("unauthorized")
    # Identifiant exigé s'il est réglé.
    ENV["PARTIDUO_TELEDEC_CALLBACK_USER"] = "teledec-rappels"
    begin
      Api.callback(token, "{}").should eq("unauthorized")
      header = "Basic #{Base64.strict_encode("teledec-rappels:#{ENV["PARTIDUO_TELEDEC_CALLBACK_PASSWORD"]}")}"
      Api.callback(header, "{}").should eq("ignored")
    ensure
      ENV.delete("PARTIDUO_TELEDEC_CALLBACK_USER")
    end
    # Sans mot de passe réglé : aucun rappel admis, aucune adresse donnée.
    password = ENV.delete("PARTIDUO_TELEDEC_CALLBACK_PASSWORD") || raise "mot de passe des rappels absent"
    begin
      Api.callback(token(password), "{}").should eq("unauthorized")
      Api.callback("Basic #{Base64.strict_encode("teledec:")}", "{}").should eq("unauthorized")
      Teledec::Callbacks.url("https://dossier.exemple.fr").should be_nil
      Api.settings(S.admin).callback_password.should be_false
    ensure
      ENV["PARTIDUO_TELEDEC_CALLBACK_PASSWORD"] = password
    end
    reader = S.admin([Api::READ])
    view = Api.settings(reader)
    {view.callback_path, view.email, view.siret, view.login, view.account_email}.should eq({"", "", "", "", ""})
    # L'ancien jeton par entreprise n'est plus écrit.
    stored = Marten::DB::Connection.default.open(&.scalar("SELECT callback_token FROM teledec_settings")).as(String)
    stored.should be_empty
  end

  it "crée le compte de l'entreprise dans le domaine du partenaire, avec le seul haché du mot de passe" do
    S.books
    sale
    Api.save_credentials(S::SYSTEM, credentials_input(email: "")).value!.email.should eq("")
    filing = S.liasse
    # Sans domaine du partenaire : rien n'est envoyé, message de configuration.
    Teledec::Transports.current = Sim.new(user_domain: nil)
    Api.transmit(S.admin, filing.id).error_keys.should eq(["teledec.errors.transport.user_domain"])
    I18n.t("teledec.errors.transport.user_domain").should contain("PARTIDUO_TELEDEC_USER_DOMAIN")
    S.teledec.requests.none?(&.path.==("/service/liasse")).should be_true
    Api.settings(S.admin).account_email.should eq("")
    Teledec::Transports.current = Sim.new
    Api.transmit(S.admin, filing.id).value!.status.should eq("transmitted")
    lines = S.teledec.requests.reverse_each.find!(&.path.==("/service/liasse")).body.lines
    lines.should contain("#EMAIL #{Sim::ACCOUNT}")
    hash = Teledec::Settings.current!.account_password_hash.to_s
    hash.should start_with("$2a$12$")
    lines.should contain("#MOT-DE-PASSE #{hash}")
    S.teledec.accounts[Sim::ACCOUNT].should eq(hash)
    Teledec::Settings.current!.account_env.should eq("sandbox")
    # Format réglable, `{siren}` obligatoire.
    Teledec::Remote::Account.email("732829320", "exemple.test", "tdc+{siren}").should eq("tdc+732829320@exemple.test")
    Teledec::Remote::Account.format("sans-siren").should be_nil
    Teledec::Remote::Account.domain("pas un domaine").should be_nil
  end

  it "exige le droit de transmettre, et garde le dépôt préparé si TELEDEC refuse l'envoi" do
    S.books
    sale
    S.connect
    filing = S.liasse
    preparer = S.admin([Api::READ, Api::PREPARE, "accounting.report.read"])
    expect_raises(Partiduo::Api::Forbidden) { Api.transmit(preparer, filing.id) }
    S.teledec.requests.none?(&.path.==("/service/liasse")).should be_true
    S.teledec.failure = "Balance déséquilibrée"
    Api.transmit(S.admin, filing.id).error_keys.should_not be_empty
    after = Api.filing(S.admin, filing.id)
    after.status.should eq("prepared")
    after.remote_url.should eq("")
    after.remote_status.should eq("")
    Api.events(S.admin, filing.id).map(&.status).should eq(%w[prepared error])
  end

  it "ne donne l'adresse des rappels à TELEDEC qu'en https, sous l'adresse publique de l'instance" do
    S.books
    S.connect
    path = Api.settings(S.admin).callback_path
    path.should eq("/hooks/TELEDEC/callback")
    Teledec::Callbacks.url(nil).should be_nil
    Teledec::Callbacks.url("").should be_nil
    Teledec::Callbacks.url("ftp://dossier.exemple.fr").should be_nil
    # Jamais en clair : le mot de passe `Basic` circulerait sans chiffrement.
    Teledec::Callbacks.url("http://localhost:8000").should be_nil
    Teledec::Callbacks.url("https://dossier.exemple.fr/").should eq("https://dossier.exemple.fr#{path}")
    # Par défaut : domaine de la société (réglage de l'instance), pas la requête.
    Teledec::Callbacks.instance_base_url.should eq("https://demo.partiduo.localhost")
    Teledec::Callbacks.url.should eq("https://demo.partiduo.localhost#{path}")
    Api.settings(S.admin).callback_url.should eq("https://demo.partiduo.localhost#{path}")
    Api.settings(S.admin([Api::READ])).callback_url.should eq("")
  end

  it "prend l'hôte de l'instance dans PARTIDUO_HOST ou MARTEN_ALLOWED_HOSTS quand la société n'a pas de domaine" do
    S.books
    Marten::DB::Connection.default.open(&.exec("UPDATE core_settings SET domain = ''"))
    previous = {ENV["PARTIDUO_HOST"]?, ENV["MARTEN_ALLOWED_HOSTS"]?}
    begin
      ENV.delete("PARTIDUO_HOST")
      ENV["MARTEN_ALLOWED_HOSTS"] = "*.exemple.fr,dossier.exemple.fr"
      Teledec::Callbacks.instance_base_url.should be_nil # joker : pas un hôte
      ENV["MARTEN_ALLOWED_HOSTS"] = "compta.exemple.fr,autre.exemple.fr"
      Teledec::Callbacks.instance_base_url.should eq("https://compta.exemple.fr")
      ENV["PARTIDUO_HOST"] = "Dossier.Exemple.fr:8443"
      Teledec::Callbacks.instance_base_url.should eq("https://dossier.exemple.fr:8443")
    ensure
      previous[0] ? (ENV["PARTIDUO_HOST"] = previous[0]) : ENV.delete("PARTIDUO_HOST")
      previous[1] ? (ENV["MARTEN_ALLOWED_HOSTS"] = previous[1]) : ENV.delete("MARTEN_ALLOWED_HOSTS")
    end
  end

  it "ignore les rappels de paiement et ceux d'un autre type de déclaration" do
    filing = transmitted_liasse
    S.teledec.acknowledge(S::LIASSE_ID)
    body = JSON.parse(S.teledec.callback_body(S::LIASSE_ID)).as_h
    payment = body.merge({"declarationType" => JSON::Any.new("Paiement"), "status" => JSON::Any.new("ERREUR"),
                          "formulairesStatus" => JSON::Any.new(""), "paiementStatus" => JSON::Any.new("Rejected"),
                          "erreurLibelle" => JSON::Any.new("prélèvement refusé")})
    Api.callback(token, payment.to_json).should eq("ignored")
    Api.callback(token, body.merge({"declarationType" => JSON::Any.new("Paiement")}).to_json).should eq("ignored")
    Api.callback(token, body.merge({"declarationType" => JSON::Any.new("TVA")}).to_json).should eq("ignored")
    unchanged = Api.filing(S.admin, filing.id)
    unchanged.status.should eq("transmitted")
    unchanged.rejection_reason.should eq("")
    Api.callback(token, body.to_json).should eq("ok")
    Api.filing(S.admin, filing.id).status.should eq("acknowledged")
  end

  it "n'applique pas à un nouvel envoi le rappel ou le compte-rendu d'un envoi précédent" do
    filing = transmitted_liasse
    S.teledec.reject(S::LIASSE_ID, "SIREN inconnu")
    old = S.teledec.callback_body(S::LIASSE_ID)
    old_report = S.teledec.deposits[S::LIASSE_ID].report
    Api.callback(token, old).should eq("ok")
    S.liasse
    again = Api.transmit(S.admin, filing.id).value!
    again.status.should eq("transmitted")
    # Rappel tardif de l'envoi rejeté : sa référence n'est plus celle du
    # dépôt, l'identifiant de la déclaration ne suffit pas.
    Api.callback(token, old).should eq("ignored")
    Api.filing(S.admin, filing.id).status.should eq("transmitted")
    # TELEDEC rend encore l'ancien ERREUR et son compte-rendu : en attente.
    deposit = S.teledec.deposits[S::LIASSE_ID]
    deposit.status = "ERREUR"
    deposit.report = old_report
    refreshed = Api.refresh(S.admin, filing.id).value!
    refreshed.status.should eq("transmitted")
    refreshed.rejection_reason.should eq("")
    # Compte-rendu du nouvel envoi : il fait foi.
    S.teledec.reject(S::LIASSE_ID, "Balance déséquilibrée")
    rejected = Api.refresh(S.admin, filing.id).value!
    rejected.status.should eq("rejected")
    rejected.rejection_reason.should eq("Balance déséquilibrée")
  end

  it "ignore le rappel d'un dépôt noté à la main, et retrouve un dépôt par l'identifiant de la déclaration" do
    S.books
    sale
    S.connect
    filing = S.liasse
    Api.record_outcome(S.admin, filing.id, Api::OutcomeInput.new("transmitted", reference: "WEB-1")).value!
    Api.callback(token, %({"reference": "WEB-1", "declarationId": 5, "status": "OK"})).should eq("ignored")
    Api.filing(S.admin, filing.id).status.should eq("transmitted")

    other = transmitted_liasse_for_declaration
    Api.callback(token, %({"declarationId": "D-77", "status": "OK", "formulairesStatus": "OK"})).should eq("ok")
    Api.filing(S.admin, other.id).status.should eq("acknowledged")
  end

  it "ne revient pas sur un accusé : un rejet tardif ne change rien" do
    filing = transmitted_liasse
    S.teledec.acknowledge(S::LIASSE_ID)
    Api.callback(token, S.teledec.callback_body(S::LIASSE_ID)).should eq("ok")
    body = JSON.parse(S.teledec.callback_body(S::LIASSE_ID)).as_h
    {"status" => "ERREUR", "formulairesStatus" => "ERREUR", "erreurLibelle" => "tardif"}.each { |name, value| body[name] = JSON::Any.new(value) }
    body["declarationId"] = JSON::Any.new(999_i64)
    late = body.to_json
    Api.callback(token, late).should eq("ok")
    done = Api.filing(S.admin, filing.id)
    done.status.should eq("acknowledged")
    done.rejection_reason.should eq("")
  end

  it "ignore le rappel d'un envoi précédent une fois le dépôt rejeté puis préparé de nouveau" do
    filing = transmitted_liasse
    S.teledec.reject(S::LIASSE_ID, "SIREN inconnu")
    old = S.teledec.callback_body(S::LIASSE_ID)
    Api.callback(token, old).should eq("ok")
    Api.filing(S.admin, filing.id).status.should eq("rejected")
    again = S.liasse
    again.id.should eq(filing.id)
    again.status.should eq("prepared")
    Api.callback(token, old.sub(%("ERREUR"), %("OK"))).should eq("ignored")
    Api.filing(S.admin, filing.id).status.should eq("prepared")
  end

  it "refuse un rappel trop volumineux ou qui n'est pas un objet JSON" do
    transmitted_liasse
    Api.callback(token, "[1, 2]").should eq("invalid")
    Api.callback(token, " " * (Teledec::Callbacks::MAX_BYTES + 1)).should eq("invalid")
    Api.callback(token("#{ENV["PARTIDUO_TELEDEC_CALLBACK_PASSWORD"]}x"), "{}").should eq("unauthorized")
    Api.callback("", "{}").should eq("unauthorized")
  end

  it "lève ModuleDisabled sur un rappel quand l'extension est inactive" do
    transmitted_liasse
    presented = token
    Partiduo::Api::Modules.deactivate(S::SYSTEM, Teledec::CODE).value!
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.callback(presented, "{}") }
  end

  it "contrôle en base le SIRET des paramètres et l'unicité de l'identifiant de déclaration" do
    S.books
    sql_error("UPDATE teledec_settings SET siret = '1234'").to_s.should contain("teledec_settings_siret_check")
    sql_error("UPDATE teledec_settings SET siret = '7328293200007A'").to_s.should contain("teledec_settings_siret_check")
    sql_error("UPDATE teledec_settings SET siret = ''").should be_nil
    sql_error("UPDATE teledec_settings SET siret = '73282932000074'").should be_nil
    insert = <<-SQL
      INSERT INTO teledec_filing (key, kind, forms, year, number, period_from, period_to, status, payload, fingerprint,
        controls, remote_id, rejection_reason, last_error, manual, prepared_at, created_at, updated_at, declaration_id)
      VALUES ($1, 'liasse', '2065', 2026, 0, '2026-01-01', '2026-12-31', 'transmitted', '{}', 'x', '[]', $1, '', '', false,
        now(), now(), now(), $2)
      SQL
    sql_error(insert, "liasse:1", "").should be_nil
    sql_error(insert, "liasse:2", "").should be_nil
    sql_error(insert, "liasse:3", "D-1").should be_nil
    sql_error(insert, "liasse:4", "D-1").to_s.should contain("teledec_filing_declaration_id_key")
  end
end

# Liasse transmise d'un second exercice (2027), sans référence connue du
# rappel : seul l'identifiant de la déclaration la désigne.
private def transmitted_liasse_for_declaration : Api::FilingView
  year = PartiduoUi::Reference.fiscal_year(2027)
  Books.sale(Books.card("CUSTOMER", "Atelier Morel").code, "500", "2027-02-10")
  filing = S.prepare("liasse", fiscal_year_id: year.id)
  sent = Api.transmit(S.admin, filing.id).value!
  Marten::DB::Connection.default.open(&.exec("UPDATE teledec_filing SET declaration_id = 'D-77' WHERE id = $1", sent.id))
  sent
end
