# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"
require "crypto/bcrypt/password"
require "http/server"

# Suite d'intégration contre l'environnement de test (stage) de TELEDEC,
# par l'adaptateur réel (`Teledec::HttpTransport`) : jeton, création d'une
# entreprise de test, liasse d'une balance de démonstration (URL rendue),
# CA3, DAS2 et relevé d'acompte d'IS 2571 en marque blanche, 2035 d'un
# libéral sans Comptabilité (seconde entreprise de test, régime BNC),
# rappels de TELEDEC reçus par la réception réelle de l'extension. Activée
# seulement si `~/.config/partiduo/teledec-sandbox.env` porte
# `TELEDEC_SANDBOX_CLIENT_ID` et `TELEDEC_SANDBOX_CLIENT_SECRET` ; aucune
# valeur du fichier n'est jamais affichée, journalisée ni copiée (les
# messages d'échec sont expurgés, `SandboxSpec.scrub`). Les dépôts exigent
# aussi le domaine déclaré comme partenaire chez TELEDEC
# (`TELEDEC_USER_DOMAIN`, comptes des entreprises de test en marque
# blanche) ; sans lui, ils restent en attente.
#
# Le fichier étant déjà dans le dossier de configuration de Partiduo, ses
# réglages s'écrivent sans le préfixe `PARTIDUO_` : `TELEDEC_USER_DOMAIN`,
# `TELEDEC_USER_FORMAT`, `TELEDEC_SOURCE` sont passés à l'adaptateur de la
# suite (l'environnement les fixe sous leur nom d'instance,
# `PARTIDUO_TELEDEC_…`, s'il y a lieu), sans être recopiés dans
# l'environnement du processus : les autres specs gardent leurs valeurs de
# test. Tout part sur le stage (`sandbox`) : rien n'est transmis à la
# DGFiP, et la liasse est envoyée sans bouton « Envoyer ».
#
# Rappels (callbacks) : l'exemple ne s'active que si `TELEDEC_CALLBACK_URL`
# (adresse publique https qui mène au port d'écoute de l'exemple : tunnel
# vers ce poste) et `TELEDEC_CALLBACK_PASSWORD` (mot de passe des rappels du
# partenaire, configuré chez TELEDEC) sont réglés ; identifiant facultatif
# `TELEDEC_CALLBACK_USER`, port d'écoute `TELEDEC_CALLBACK_PORT` (défaut
# 8787), attente `TELEDEC_CALLBACK_WAIT` (secondes, ou `5m`, défaut 5
# minutes). Ces réglages se lisent dans le fichier, ou dans l'environnement
# sous le même nom (qui prime : pratique pour l'adresse d'un tunnel
# éphémère). Le mot de passe et l'identifiant ne sont appliqués au processus
# (`PARTIDUO_TELEDEC_CALLBACK_*`) que le temps de cet exemple : les autres
# specs gardent leur valeur de test. Tunnel, dans un autre terminal :
#
#   cloudflared tunnel --url http://localhost:8787   # https://….trycloudflare.com
#   ngrok http 8787                                  # https://….ngrok-free.app
#
# puis `TELEDEC_CALLBACK_URL=https://…` (adresse de base ; le chemin
# `/hooks/TELEDEC/callback` est ajouté s'il manque).
module Teledec::SandboxSpec
  FILE = File.join(ENV["HOME"]? || "/nonexistent", ".config/partiduo/teledec-sandbox.env")
  # Entreprise fictive (SIREN à clé valide, non attribué à notre
  # connaissance), email de contact sur un domaine réservé.
  EMAIL = "partiduo-stage@example.org"
  SIREN = "999888779"
  SIRET = "99988877900017"
  # Seconde entreprise fictive, distincte (autre SIREN à clé valide, donc
  # autre compte en marque blanche) : libéral au régime BNC, sans
  # Comptabilité, pour ne pas mélanger les régimes.
  LIBERAL_SIREN = "999888662"
  LIBERAL_SIRET = "99988866200015"
  # SIRET fictif (clé valide) de la société bénéficiaire de la DAS2.
  BENEFICIARY_SIRET = "99977755000016"
  # Réglages de l'instance repris du fichier (sans le préfixe `PARTIDUO_`).
  SETTINGS = %w[TELEDEC_USER_DOMAIN TELEDEC_USER_FORMAT TELEDEC_SOURCE]
  # Réglages des rappels (voir l'en-tête), lus par `setting`.
  CALLBACK_PORT = 8787
  CALLBACK_WAIT = 5.minutes

  # Réglages du fichier, lus une fois ; vide sans fichier.
  class_getter file_values : Hash(String, String) do
    values = {} of String => String
    begin
      File.each_line(FILE) do |line|
        name, sep, value = line.strip.lchop("export ").partition('=')
        next if sep.empty? || name.starts_with?('#')
        values[name.strip] = value.strip.strip('"').strip('\'')
      end
    rescue File::Error
    end
    values
  end

  def self.values : Hash(String, String)?
    found = file_values
    found if found["TELEDEC_SANDBOX_CLIENT_ID"]?.presence && found["TELEDEC_SANDBOX_CLIENT_SECRET"]?.presence
  end

  # Réglage de l'instance (`SETTINGS`) : nom d'instance dans
  # l'environnement (`PARTIDUO_…`), sinon fichier. Passé explicitement à
  # l'adaptateur, jamais recopié dans l'environnement du processus : les
  # autres specs de la suite complète gardent leurs valeurs de test.
  def self.instance_setting(name : String) : String?
    ENV["PARTIDUO_#{name}"]?.presence || file_values[name]?.presence
  end

  # Réglage de la suite : environnement sous le même nom, sinon fichier.
  def self.setting(name : String) : String?
    ENV[name]?.presence || file_values[name]?.presence
  end

  # Texte sans aucune valeur du fichier de configuration (identifiants,
  # domaine, mot de passe des rappels, adresse publique…) ni haché bcrypt,
  # borné : ce qui peut figurer dans un message d'échec.
  def self.scrub(text : String) : String
    clean = text.gsub(/\$2[aby]?\$\d\d\$[.\/A-Za-z0-9]{53}/, "***")
    (file_values.values + SETTINGS.compact_map { |name| instance_setting(name) }).each do |secret|
      clean = clean.gsub(secret, "***") if secret.size >= 4
    end
    clean = clean.gsub(/\s+/, " ").strip
    clean.size > 2000 ? "#{clean[0, 2000]}…" : clean
  end

  def self.credentials(secret : String? = nil, siret : String = SIRET, account_ready : Bool = false) : Credentials
    found = values || raise "identifiants du stage absents"
    Credentials.new(found["TELEDEC_SANDBOX_CLIENT_ID"], secret || found["TELEDEC_SANDBOX_CLIENT_SECRET"], "sandbox", EMAIL,
      siret, password_hash: password_hash, account_ready: account_ready)
  end

  # Haché du mot de passe des comptes de test (un par exécution).
  class_getter password_hash : String { Remote::Account.new_password_hash }

  # Adresse du compte d'une entreprise de test ; en attente sans domaine du
  # partenaire.
  def self.account!(siren : String = SIREN) : String
    transport.account_email(siren)
  rescue TransportError
    pending!("domaine du partenaire non réglé (TELEDEC_USER_DOMAIN du fichier de configuration)")
  end

  def self.transport(exchange : Remote::Exchange = Remote::Net.new) : HttpTransport
    HttpTransport.new(exchange, source: instance_setting("TELEDEC_SOURCE"), send_button: false,
      user_domain: instance_setting("TELEDEC_USER_DOMAIN"), user_format: instance_setting("TELEDEC_USER_FORMAT"))
  end

  # Échange réel qui garde le dernier corps rendu par chaque route : les
  # libellés d'erreur de TELEDEC que le suivi ne remonte pas.
  class Recorder < Remote::Exchange
    getter bodies = {} of String => String

    def initialize(@inner : Remote::Exchange = Remote::Net.new)
    end

    def call(request : Remote::Request) : Remote::Response
      response = @inner.call(request)
      @bodies[request.path] = response.body
      response
    end
  end

  @@reachable : Bool? = nil

  # Le stage est-il joignable depuis ce processus (réseau, pare-feu) ?
  # Sinon les exemples passent en attente au lieu d'échouer.
  def self.require_stage! : Nil
    reachable = @@reachable
    if reachable.nil?
      reachable = begin
        transport.check(credentials)
        true
      rescue ex : TransportError
        ex.key != "teledec.errors.transport.unreachable"
      end
      @@reachable = reachable
    end
    pending!("stage de TELEDEC injoignable depuis ce processus (réseau)") unless reachable
  end

  # Dépôt ; un refus de TELEDEC fait échouer l'exemple avec son message
  # (expurgé) : c'est l'information cherchée.
  def self.deposit!(transport : HttpTransport, credentials : Credentials, submission : Submission, what : String) : Submitted
    transport.submit(credentials, submission)
  rescue ex : TransportError
    fail "#{what} refusée : #{ex.key} — #{scrub(ex.params.values.join(" ; ").presence || "sans message de TELEDEC")}"
  end

  # États bruts de TELEDEC qui peuvent précéder ses contrôles.
  UNSETTLED = {"", "notfound", "notcompleted"}

  # État du dépôt une fois lu par TELEDEC (jusqu'à 30 s) ; échec si
  # TELEDEC ne le trouve pas ou si ses contrôles signalent
  # `CompleteWithErrors`, avec les libellés de ses erreurs (expurgés).
  def self.settled_status!(recorder : Recorder, transport : HttpTransport, credentials : Credentials,
                           remote_id : String, what : String) : RemoteStatus
    status = transport.status(credentials, remote_id)
    6.times do
      break unless UNSETTLED.includes?(status.remote_status)
      sleep 5.seconds
      status = transport.status(credentials, remote_id)
    end
    fail "#{what} : TELEDEC ne trouve pas le dépôt (declaration-status)" if status.remote_status == "notfound"
    if status.remote_status == "completewitherrors"
      fail "#{what} : contrôles de TELEDEC en erreur (CompleteWithErrors) — #{errors(recorder, transport, credentials, remote_id)}"
    end
    status
  end

  # Libellés des erreurs de TELEDEC : réponse du suivi, puis
  # comptes-rendus.
  def self.errors(recorder : Recorder, transport : HttpTransport, credentials : Credentials, remote_id : String) : String
    found = labels(recorder.bodies["/service/declaration-status"]? || "")
    key = Remote::Formats::Key.parse(remote_id)
    if key && found.empty?
      transport.reports(credentials, key).each { |report| found << report.reason unless report.reason.empty? }
    end
    scrub(found.uniq.join(" ; ").presence || "aucun libellé d'erreur dans la réponse de TELEDEC")
  rescue TransportError
    "libellés illisibles"
  end

  LABEL_FIELDS = %w[message erreurLibelle statusLibelle libelle label]

  # Erreurs d'une réponse JSON : `declarationErreurs` lues comme en
  # production (`Remote::Formats.reason`), puis tout libellé rencontré.
  def self.labels(body : String) : Array(String)
    found = [] of String
    collect(JSON.parse(body), found)
    found
  rescue JSON::ParseException
    body.blank? ? [] of String : [body]
  end

  private def self.collect(node : JSON::Any, found : Array(String)) : Nil
    if hash = node.as_h?
      reason = Remote::Formats.reason(hash, "")
      found << reason unless reason.empty?
      hash.each do |name, value|
        text = value.as_s?
        if text && LABEL_FIELDS.includes?(name)
          found << text unless text.blank?
        else
          collect(value, found)
        end
      end
    elsif list = node.as_a?
      list.each { |item| collect(item, found) }
    end
  end

  def self.identity(siren : String = SIREN) : Payload::Identity
    Payload::Identity.new("PARTIDUO ESSAI", "SAS", siren, "", "", "1000.00", "3 rue des Lilas", "69003", "Lyon",
      "FR", EMAIL)
  end

  # Identité de l'entreprise de test pour `creation-entreprise` : société
  # à l'IS, régime simplifié (`ISRS`), TVA au réel normal.
  def self.company_identity : Hash(String, String | Int32)
    {"siren" => SIREN, "name" => "PARTIDUO ESSAI", "yearEndMonth" => 12, "yearEndDay" => 31,
     "addressStreet" => "3 rue des Lilas", "addressPostalCode" => "69003", "addressCity" => "Lyon",
     "addressCountry" => "FR", "legalForm" => "SAS", "fullRegimeFiscal" => "ISRS",
     "regimeFiscalTVA" => "Normal"} of String => String | Int32
  end

  # Balance de démonstration d'un premier exercice : capital, banque,
  # clients, ventes et TVA, achats ; équilibrée.
  def self.liasse_payload : Payload
    rows = [
      {"101000", "Capital", "0.00", "1000.00", "0.00", "1000.00"},
      {"401000", "Fournisseurs", "1800.00", "1800.00", "0.00", "0.00"},
      {"411000", "Clients", "8744.33", "8744.33", "0.00", "0.00"},
      {"445660", "TVA déductible", "300.00", "0.00", "300.00", "0.00"},
      {"445710", "TVA collectée", "0.00", "1457.39", "0.00", "1457.39"},
      {"512000", "Banque", "9744.33", "1800.00", "7944.33", "0.00"},
      {"606400", "Fournitures administratives", "1500.00", "0.00", "1500.00", "0.00"},
      {"706000", "Prestations de services", "0.00", "7286.94", "0.00", "7286.94"},
    ].map { |row| Payload::BalanceRow.new(*row) }
    Payload.new("liasse", %w[2065 2033], identity, "2025-01-01", "2025-12-31", 0, rows)
  end

  def self.ca3_payload(month : Int32 = 8) : Payload
    boxes = {"3310-CA3" => {"A1" => "1000", "08.base" => "1000", "08.tax" => "200", "16" => "200", "20" => "50",
                            "23" => "50", "28" => "150", "32" => "150"}}
    last = Time.utc(2026, month, 1).at_end_of_month.to_s("%F")
    Payload.new("vat_ca3", ["3310-CA3"], identity, "2026-#{month.to_s.rjust(2, '0')}-01", last, month, nil, nil, boxes,
      nil, {"periodicity" => "month"})
  end

  # DAS2 de 2025 : une société (raison sociale et SIRET) payée de deux
  # natures (honoraires et commissions : sous-tableau
  # `repetitionDAS2MontantSommesVersees`), une personne physique (nom,
  # prénoms, date de naissance) payée de droits d'auteur.
  def self.das2_payload : Payload
    lines = [
      Payload::Das2Line.new("F-CONSEIL", "CABINET CONSEIL ESSAI", BENEFICIARY_SIRET, "Conseil", "12 quai Perrache",
        "69002", "Lyon", "FR", {"fees" => "2400", "commissions" => "1500"}, "3900"),
      Payload::Das2Line.new("F-MARTIN", "MARTIN Claire", "", "Auteure", "8 rue Mercière", "69002", "Lyon", "FR",
        {"copyright" => "1800"}, "1800", person: true, last_name: "MARTIN", first_names: "Claire",
        birth_date: "1980-05-14"),
    ]
    Payload.new("das2", ["DAS2"], identity, "2025-01-01", "2025-12-31", 0, nil, nil, nil, lines, {"threshold" => "1200"})
  end

  # Quatrième relevé d'acompte d'IS de l'exercice 2026 : 2 500 €.
  def self.advance_payload : Payload
    Payload.new("is_2571", ["2571"], identity, "2026-01-01", "2026-12-31", 4, nil, nil, nil, nil, {"amount" => "2500"})
  end

  # 2035 d'un libéral sans Comptabilité, construite *par l'extension* dans
  # la base de test (DECISIONS D-TDC2-002) : module `liberal` seul, régime
  # BNC, exercice 2025, livre-journal d'un kinésithérapeute ; aucune ligne
  # de balance, les cases de la 2035 préparée par `liberal`. L'identité du
  # document est remplacée par celle de la seconde entreprise de test.
  def self.liberal_payload : Payload
    PartiduoUi::Reference.provision("fr")
    fiscal_year = PartiduoUi::Reference.fiscal_year(2025)
    actor = Partiduo::Api::Actor.user(PartiduoUi::Accounts.create.user.id, SpecSupport::LIBERAL, level: 3)
    Partiduo::Api::Modules.activate(SpecSupport::SYSTEM, "LIBERAL").value!
    Partiduo::Api::Liberal.load_defaults(SpecSupport::SYSTEM)
    Partiduo::Api::Liberal.update_settings(SpecSupport::SYSTEM, Partiduo::Api::Liberal::SettingsInput.new(
      profession: "Masseur-kinésithérapeute", default_nature_id: SpecSupport.liberal_nature("RECEIPTS").id)).value!
    Partiduo::Api::Modules.activate(SpecSupport::SYSTEM, CODE).value!
    Partiduo::Api::Modules.deactivate(SpecSupport::SYSTEM, "ACCOUNTING").value!
    SpecSupport.liberal_line("receipt", "2025-03-03", "42000", "RECEIPTS")
    SpecSupport.liberal_line("expense", "2025-03-04", "9600", "RENT")
    SpecSupport.liberal_line("expense", "2025-03-05", "850", "OFFICE")
    filing = Api.prepare(actor, Api::PrepareInput.new(kind: "liasse", fiscal_year_id: fiscal_year.id)).value!
    unless filing.ready?
      raise "2035 non prête : #{filing.controls.select(&.error?).map(&.key).join(", ")}"
    end
    built = Payload.from_json(Filing.get!(id: filing.id).payload.to_s)
    identity = Payload::Identity.new("PARTIDUO ESSAI LIBERAL", "EI", LIBERAL_SIREN, "", "", nil, "5 place Bellecour",
      "69002", "Lyon", "FR", EMAIL)
    Payload.new(built.kind, built.forms, identity, built.period_from, built.period_to, built.number, built.balance,
      built.previous_balance, built.boxes, nil, built.details)
  end

  def self.submission(payload : Payload, due_on : String? = nil, year_end : String = "2025-12-31",
                      callback_url : String? = nil) : Submission
    json = payload.to_json
    Submission.new("partiduo-stage-#{payload.kind}-#{Time.utc.to_unix}", payload.kind, payload.forms, json,
      payload.fingerprint, due_on: due_on, year_end: year_end, callback_url: callback_url)
  end

  # --- Rappels -----------------------------------------------------------------

  def self.callback_port : Int32
    setting("TELEDEC_CALLBACK_PORT").try(&.to_i?) || CALLBACK_PORT
  end

  # Attente d'un rappel : secondes (`300`, `300s`) ou minutes (`5m`).
  def self.callback_wait : Time::Span
    text = setting("TELEDEC_CALLBACK_WAIT") || return CALLBACK_WAIT
    if match = text.strip.match(/\A(\d+)\s*(s|m|min)?\z/)
      value = match[1].to_i
      return match[2]?.try(&.starts_with?('m')) ? value.minutes : value.seconds
    end
    CALLBACK_WAIT
  end

  # Adresse des rappels donnée à TELEDEC, formée comme en production
  # (`Callbacks.url` : https seulement) depuis l'adresse publique réglée,
  # avec ou sans le chemin des rappels ; `nil` si elle n'est pas en https.
  def self.callback_target(public_url : String) : String?
    Callbacks.url(public_url.strip.rstrip('/').chomp(Callbacks::PATH))
  end

  # Applique au processus, le temps du bloc, le mot de passe (et
  # l'identifiant) des rappels du partenaire ; rend ensuite leurs valeurs
  # de test aux autres specs.
  def self.with_callback_password(password : String, &)
    names = {Callbacks::PASSWORD_VARIABLE, Callbacks::USER_VARIABLE}
    previous = names.map { |name| ENV[name]? }
    begin
      ENV[Callbacks::PASSWORD_VARIABLE] = password
      if user = setting("TELEDEC_CALLBACK_USER")
        ENV[Callbacks::USER_VARIABLE] = user
      else
        ENV.delete(Callbacks::USER_VARIABLE)
      end
      yield
    ensure
      names.each_with_index do |name, index|
        value = previous[index]
        value ? (ENV[name] = value) : ENV.delete(name)
      end
    end
  end

  # Serveur HTTP minimal de réception, dans ce processus : chaque `POST` du
  # chemin des rappels passe par le gestionnaire réel de l'extension
  # (`Teledec::Ui::CallbackHandler`, puis `Api.callback`,
  # `Callbacks.authenticate` et `Callbacks.receive`), exactement comme la
  # route de l'instance ; le code rendu et le corps reçu sont gardés.
  class CallbackReceiver
    record Received, status : Int32, body : String

    getter port : Int32
    @received = Channel(Received).new(32)

    def initialize(@port : Int32)
      @server = ::HTTP::Server.new { |context| handle(context) }
    end

    def start : self
      @server.bind_tcp("127.0.0.1", @port)
      spawn { @server.listen }
      self
    end

    def close : Nil
      @server.close unless @server.closed?
    end

    # Premier rappel reçu dans le délai, sinon `nil`.
    def wait(span : Time::Span) : Received?
      select
      when item = @received.receive
        item
      when timeout(span)
        nil
      end
    end

    # Code rendu par la réception réelle pour ce corps et cet en-tête
    # `Authorization`.
    def dispatch(body : String, authorization : String?) : Int32
      headers = ::HTTP::Headers{"Host" => "127.0.0.1", "Content-Type" => "application/json",
                                "Content-Length" => body.bytesize.to_s}
      authorization.try { |value| headers["Authorization"] = value }
      raw = ::HTTP::Request.new("POST", Callbacks::PATH, headers, IO::Memory.new(body))
      Ui::CallbackHandler.new(Marten::HTTP::Request.new(raw)).dispatch.status
    end

    private def handle(context : ::HTTP::Server::Context) : Nil
      request = context.request
      unless request.method == "POST" && request.path == Callbacks::PATH
        context.response.status_code = 404
        return
      end
      body = begin
        Remote::Net.read_limited(request.body, Callbacks::MAX_BYTES)
      rescue TransportError
        context.response.status_code = 413
        return
      end
      status = dispatch(body, request.headers["Authorization"]?)
      context.response.status_code = status
      context.response.content_type = "application/json"
      context.response.print %({"status": #{status}})
      @received.send(Received.new(status, body))
    end
  end
end

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
      answer.should contain(account)
    end

    it "envoie la liasse d'une balance de démonstration (URL rendue, source `API`)" do
      Sandbox.require_stage!
      Sandbox.account!
      transport = Sandbox.transport
      submission = Sandbox.submission(Sandbox.liasse_payload)
      submitted = transport.submit(Sandbox.credentials, submission)
      submitted.url.should start_with("https://stage.teledec.fr")
      submitted.remote_id.should eq("liasse:#{Sandbox::SIREN}:2025-12-31")
      status = transport.status(Sandbox.credentials, "liasse:#{Sandbox::SIREN}:2025-12-31")
      status.state.should eq("pending")
    end

    it "dépose une CA3 en marque blanche (lien rendu), puis en relève l'état" do
      Sandbox.require_stage!
      Sandbox.account!
      transport = Sandbox.transport
      submission = Sandbox.submission(Sandbox.ca3_payload, due_on: "2026-09-19")
      submitted = transport.submit(Sandbox.credentials, submission)
      submitted.remote_id.should eq("3310CA3:#{Sandbox::SIREN}:2026-08-31:2026-09-19")
      submitted.url.should start_with("https://stage.teledec.fr/")
      status = transport.status(Sandbox.credentials, submitted.remote_id)
      status.state.should eq("pending")
      status.remote_status.should eq("readytobesent")
    end

    it "dépose une DAS2 en marque blanche (société à deux natures, personne physique) sans erreur bloquante de TELEDEC" do
      Sandbox.require_stage!
      Sandbox.account!
      recorder = Sandbox::Recorder.new
      transport = Sandbox.transport(recorder)
      credentials = Sandbox.credentials
      due_on = Teledec::Calendar.das2(2025).to_s("%F")
      submitted = Sandbox.deposit!(transport, credentials, Sandbox.submission(Sandbox.das2_payload, due_on: due_on), "DAS2")
      submitted.url.should start_with("https://stage.teledec.fr/")
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
      submitted.url.should start_with("https://stage.teledec.fr/")
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
      Sandbox.require_stage!
      Sandbox.account!(Sandbox::LIBERAL_SIREN).should_not eq(Sandbox.account!)
      transport = Sandbox.transport
      credentials = Sandbox.credentials(siret: Sandbox::LIBERAL_SIRET)
      submitted = Sandbox.deposit!(transport, credentials, Sandbox.submission(payload), "Liasse 2035 sans balance")
      submitted.url.should start_with("https://stage.teledec.fr")
      submitted.remote_id.should eq("liasse:#{Sandbox::LIBERAL_SIREN}:2025-12-31")
      transport.status(credentials, submitted.remote_id).state.should eq("pending")
    end

    it "reçoit un rappel de TELEDEC authentifié, accepté par la réception de l'extension ; un mauvais mot de passe est refusé" do
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
          STDOUT.puts "\n  En attente d'un rappel de TELEDEC (#{wait.total_seconds.to_i} s au plus, port #{receiver.port})…"
          received = receiver.wait(wait) ||
                     fail "aucun rappel reçu en #{wait.total_seconds.to_i} s pour #{submitted.remote_id} : TELEDEC ne " \
                          "rappelle peut-être qu'à l'envoi (vérifier le tunnel vers le port #{receiver.port}, ou " \
                          "allonger TELEDEC_CALLBACK_WAIT)"
          if received.status != 200
            fail "rappel reçu mais refusé par la réception de l'extension (HTTP #{received.status}) : " \
                 "#{received.status == 401 ? "mot de passe du rappel différent de TELEDEC_CALLBACK_PASSWORD" : "corps illisible"}"
          end
          report = Teledec::Remote::Formats.report(JSON.parse(received.body))
          concerned = report.reference == submission.reference ||
                      JSON.parse(received.body)["siren"]?.try(&.as_s?) == Sandbox::SIREN
          fail "rappel reçu pour une autre déclaration" unless concerned
          user = Sandbox.setting("TELEDEC_CALLBACK_USER") || "teledec"
          wrong = "Basic #{Base64.strict_encode("#{user}:#{password}-faux")}"
          receiver.dispatch(received.body, wrong).should eq(401)
          receiver.dispatch(received.body, nil).should eq(401)
          receiver.dispatch(received.body, "Basic #{Base64.strict_encode("#{user}:#{password}")}").should eq(200)
        ensure
          receiver.close
        end
      end
    end
  else
    pending "identifiants du stage absents (~/.config/partiduo/teledec-sandbox.env)"
  end
end
