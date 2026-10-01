# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"
require "log/spec"

private alias S = Teledec::SpecSupport
private alias Api = Teledec::Api
private alias Acc = Partiduo::Api::Accounting
private alias Books = PartiduoUi::Books
private alias Remote = Teledec::Remote
private alias Formats = Teledec::Remote::Formats
private alias Payload = Teledec::Payload

# Schémas JSON officiels de TELEDEC : documents de TELEDEC, jamais
# versionnés dans ce dépôt. `TELEDEC_SCHEMAS_DIR`, sinon
# `../.teledec-doc/schemas` à côté du dépôt ; absents (CI), les exemples
# qui les lisent passent en attente (DECISIONS D-TDC6-002).
module Teledec::SchemaSpec
  DIR = ENV["TELEDEC_SCHEMAS_DIR"]?.presence || File.expand_path("../../../.teledec-doc/schemas", __DIR__)

  def self.store! : Remote::Schemas
    store = Remote::Schemas.new(DIR)
    pending!("schémas JSON de TELEDEC absents (#{DIR}, TELEDEC_SCHEMAS_DIR)") unless File.exists?(File.join(DIR, "index.json"))
    store
  end

  def self.identity : Payload::Identity
    Payload::Identity.new("Atelier Brunet SARL", "SARL", "732829320", "FR44732829320", "Lyon B 732 829 320", "10000",
      "12 rue des Arts", "69002", "Lyon", "FR", "contact@atelier-brunet.test")
  end

  def self.credentials : Credentials
    Credentials.new("login", "secret", "sandbox", "compta@atelier-brunet.test", "73282932000074",
      password_hash: "$2a$12$empreinte")
  end

  def self.submission(kind : String, due_on : String? = nil, year_end : String? = nil) : Submission
    Submission.new("partiduo-1-1-abcdef", kind, [] of String, "{}", "abcdef", due_on: due_on, year_end: year_end,
      callback_url: "https://dossier.exemple.fr/hooks/TELEDEC/callback")
  end

  # Document de la marque blanche de l'adaptateur réel pour `payload`.
  def self.document(payload : Payload, submission : Submission) : JSON::Any
    JSON.parse(Formats.white_label(payload, submission, credentials, Time.utc, "teledec-732829320@partiduo.test"))
  end

  # Validation du document : schéma attendu (`DAS2-2026`, `envelope`…),
  # aucun écart.
  def self.expect_valid(store : Remote::Schemas, payload : Payload, submission : Submission, schema : String) : Nil
    form = Formats.form_key(payload.kind) || raise "sorte sans formulaire"
    outcome = store.check_document(document(payload, submission), form,
      Formats.millesime_target(payload, submission.due_on))
    {payload.kind, outcome.schema_name, outcome.violations.map(&.to_s)}.should eq({payload.kind, schema, [] of String})
  end

  def self.das2_lines : Array(Payload::Das2Line)
    [
      Payload::Das2Line.new("F-CONSEIL", "CABINET CONSEIL ESSAI", "99977755000016", "Conseil", "12 quai Perrache",
        "69002", "Lyon", "FR", {"fees" => "2400", "commissions" => "1500"}, "3900"),
      Payload::Das2Line.new("F-MARTIN", "MARTIN Claire", "", "Auteure", "8 rue Mercière", "69002", "Lyon", "FR",
        {"copyright" => "1800"}, "1800", person: true, last_name: "MARTIN", first_names: "Claire",
        birth_date: "1980-05-14"),
    ]
  end

  # Schémas de fantaisie, dans un dossier temporaire : la validation à
  # l'envoi se vérifie aussi sans les documents de TELEDEC (CI).
  def self.fixtures : String
    dir = File.join(Dir.tempdir, "partiduo-teledec-schemas-#{Process.pid}-#{Random::Secure.hex(4)}")
    Dir.mkdir_p(dir)
    envelope = {"type" => "object", "required" => %w[auth identity period], "properties" => {
      "auth"     => {"type" => "object", "required" => ["email"], "properties" => {"email" => {"type" => "string", "format" => "email"}}},
      "identity" => {"type" => "object", "required" => ["siret"], "properties" => {"siret" => {"type" => "string", "minLength" => 9}}},
      "period"   => {"type" => "object", "required" => ["end"], "properties" => {"millesime" => {"type" => "integer"}}},
    }}
    File.write(File.join(dir, "envelope.json"), envelope.to_json)
    # 2572 au millésime 2025 : le bloc refuse `GE` en chaîne (type),
    # ignore les autres cases.
    form = envelope.merge({"required" => %w[auth identity period 2572], "properties" => envelope["properties"].as(Hash).merge({
      "2572" => {"type" => "object", "properties" => {"GE" => {"type" => "string"}}},
    })})
    File.write(File.join(dir, "2572-2025.json"), form.to_json)
    File.write(File.join(dir, "index.json"), {"formulaires" => [{"formId" => "2572", "millesimes" => [2025]}]}.to_json)
    dir
  end
end

private alias SchemaSpec = Teledec::SchemaSpec

describe "Validation des documents par les schémas de TELEDEC avant l'envoi (D-TDC6-003)" do
  it "sans PARTIDUO_TELEDEC_SCHEMAS_DIR, ne valide rien" do
    previous = ENV[Remote::Schemas::VARIABLE]?
    begin
      ENV.delete(Remote::Schemas::VARIABLE)
      Teledec::HttpTransport.new(Remote::Net.new).schemas.should be_nil
      ENV[Remote::Schemas::VARIABLE] = "/un/dossier"
      (Teledec::HttpTransport.new(Remote::Net.new).schemas || raise "schémas absents").dir.should eq("/un/dossier")
    ensure
      previous ? (ENV[Remote::Schemas::VARIABLE] = previous) : ENV.delete(Remote::Schemas::VARIABLE)
    end
  end

  it "refuse un document hors schéma avec une erreur traduite qui cite le chemin, sans rien envoyer" do
    S.books
    S.connect
    dir = SchemaSpec.fixtures
    S.teledec.schemas = Remote::Schemas.new(dir)
    solde = S.prepare("is_2572", fiscal_year_id: S.fiscal_year_id, amount: BigDecimal.new(9000))
    result = Api.transmit(S.admin, solde.id)
    result.error_keys.should eq(["teledec.errors.transport.schema"])
    params = result.errors.first.params
    params["schema"].should eq("2572-2025")
    params["path"].should eq("$.2572.GE")
    params["problem"].should eq("type string attendu (reçu : integer)")
    params["more"].should eq("")
    I18n.with_locale("en") { I18n.t("teledec.errors.transport.schema", params) }.should contain("$.2572.GE")
    I18n.with_locale("nl") { I18n.t("teledec.errors.transport.schema", params) }.should contain("$.2572.GE")
    S.teledec.requests.map(&.path).should_not contain("/service/declaration-marque-blanche")
    S.teledec.requests.map(&.path).should_not contain("/service/creation-entreprise")
  ensure
    dir.try { |path| FileUtils.rm_rf(path) }
  end

  it "sans schéma du formulaire, valide l'enveloppe seule et le journalise" do
    S.books
    S.connect
    dir = SchemaSpec.fixtures
    S.teledec.schemas = Remote::Schemas.new(dir)
    advance = S.prepare("is_2571", fiscal_year_id: S.fiscal_year_id, number: 2, amount: BigDecimal.new(2500))
    Log.capture do |logs|
      Api.transmit(S.admin, advance.id).value!
      logs.check(:warn, /pas de schéma 2571 au millésime 202601 ni avant \(enveloppe seule validée\)/)
    end
  ensure
    dir.try { |path| FileUtils.rm_rf(path) }
  end

  it "signale un dossier des schémas introuvable, et envoie sans valider" do
    S.books
    S.connect
    S.teledec.schemas = Remote::Schemas.new("/nulle/part/schemas")
    advance = S.prepare("is_2571", fiscal_year_id: S.fiscal_year_id, number: 2, amount: BigDecimal.new(2500))
    Log.capture do |logs|
      Api.transmit(S.admin, advance.id).value!
      logs.check(:warn, /dossier des schémas introuvable/)
    end
  end
end

describe "Documents de l'adaptateur réel contre les schémas officiels de TELEDEC (D-TDC6-002)" do
  it "interprète tous les mots-clés des schémas publiés, cohérents avec index.json" do
    store = SchemaSpec.store!
    files = Dir.glob(File.join(SchemaSpec::DIR, "*.json")).map { |path| File.basename(path, ".json") } - %w[index]
    files.size.should be > 100
    unsupported = files.flat_map do |name|
      Remote::JsonSchema.unsupported(JSON.parse(File.read(File.join(SchemaSpec::DIR, "#{name}.json")))).map { |key| "#{name} #{key}" }
    end
    unsupported.should be_empty
    %w[DAS2 2571 2572 3517SCA12 2035 2035A 2035B].each do |form|
      store.available(form).each { |millesime| File.exists?(File.join(SchemaSpec::DIR, "#{form}-#{millesime}.json")).should be_true }
    end
    store.available("DAS2").should eq([2026])
    # La CA3 n'a pas de schéma publié : l'enveloppe seule la valide.
    store.available("3310CA3").should be_empty
    store.envelope.should_not be_nil
  end

  it "valide la CA3 (enveloppe), la CA12 (3517SCA12 au palier), les relevés 2571 et 2572, la DAS2 (DAS2-2026)" do
    store = SchemaSpec.store!
    ca3 = Payload.new("vat_ca3", ["3310-CA3"], SchemaSpec.identity, "2026-07-01", "2026-07-31", 7,
      boxes: {"3310-CA3" => {"A1" => "1000", "08.base" => "1000", "08.tax" => "200", "14.TP021.base" => "100",
                             "14.TP021.tax" => "2.10", "16" => "202", "20" => "50", "23" => "50", "28" => "152", "32" => "152"}},
      details: {"periodicity" => "month"})
    SchemaSpec.expect_valid(store, ca3, SchemaSpec.submission("vat_ca3", "2026-08-19"), "envelope")
    nothing = Payload.new("vat_ca3", ["3310-CA3"], SchemaSpec.identity, "2026-07-01", "2026-09-30", 3,
      boxes: {"3310-CA3" => {"08.base" => "0"}}, details: {"periodicity" => "quarter"})
    SchemaSpec.expect_valid(store, nothing, SchemaSpec.submission("vat_ca3", "2026-10-19"), "envelope")

    ca12 = ->(year : Int32, boxes : Hash(String, String)) do
      Payload.new("vat_ca12", ["3517-S-CA12"], SchemaSpec.identity, "#{year}-01-01", "#{year}-12-31", 1,
        boxes: {"3517-S-CA12" => boxes}, details: {"periodicity" => "year"})
    end
    full = {"08.base" => "5000", "08.tax" => "1000", "09.base" => "100", "09.tax" => "5.50", "14.base" => "100",
            "14.tax" => "2.10", "16" => "1007.60", "19" => "40", "20" => "400", "sp" => "600", "ac" => "400"}
    SchemaSpec.expect_valid(store, ca12.call(2025, full), SchemaSpec.submission("vat_ca12", "2026-05-05"), "3517SCA12-202502")
    SchemaSpec.expect_valid(store, ca12.call(2026, full), SchemaSpec.submission("vat_ca12", "2027-05-05"), "3517SCA12-202601")
    SchemaSpec.expect_valid(store, ca12.call(2024, {"A1" => "0"}), SchemaSpec.submission("vat_ca12", "2025-05-05"),
      "3517SCA12-2024")

    advance = Payload.new("is_2571", %w[2571], SchemaSpec.identity, "2026-01-01", "2026-12-31", 4, details: {"amount" => "2500"})
    SchemaSpec.expect_valid(store, advance, SchemaSpec.submission("is_2571", "2026-12-15", "2026-12-31"), "2571-2025")
    solde = ->(year : Int32, tax : String) do
      Payload.new("is_2572", %w[2572], SchemaSpec.identity, "#{year}-01-01", "#{year}-12-31",
        details: {"tax" => tax, "advances" => "5000", "balance" => "0"})
    end
    SchemaSpec.expect_valid(store, solde.call(2025, "9000"), SchemaSpec.submission("is_2572", "2026-05-15"), "2572-202601")
    SchemaSpec.expect_valid(store, solde.call(2024, "3000"), SchemaSpec.submission("is_2572", "2025-05-15"), "2572-2025")

    das2 = Payload.new("das2", %w[DAS2], SchemaSpec.identity, "2025-01-01", "2025-12-31", das2: SchemaSpec.das2_lines,
      details: {"threshold" => "1200", "tax_system" => "is_rsi"})
    SchemaSpec.expect_valid(store, das2, SchemaSpec.submission("das2", "2026-05-05"), "DAS2-2026")
  end

  it "valide les cases de la 2035, 2035-A et 2035-B jointes à la liasse, bloc par bloc (le texte de la balance n'a pas de schéma)" do
    store = SchemaSpec.store!
    boxes = {"2035-A" => Formats::ZONE_2035A.to_h { |code| {code, "10"} },
             "2035-B" => Formats.zone_codes("2035-B", 202601).to_h { |code| {code, "20.50"} },
             "2035"   => Formats.zone_codes("2035", 202601).to_h { |code| {code, "30"} }}
    payload = Payload.new("liasse", %w[2035], SchemaSpec.identity, "2025-01-01", "2025-12-31", boxes: boxes)
    zones = Formats.liasse_zones(payload) || raise "zones absentes"
    zones.map do |form, values|
      outcome = store.check_block(form, JSON.parse(values.to_json), Formats.millesime_target(payload))
      {outcome.schema_name, outcome.violations.map(&.to_s)}
    end.sort!.should eq([{"2035-2026", [] of String}, {"2035A-2026", [] of String}, {"2035B-2026", [] of String}])
    # Exercice 2024 (campagne 2025) : tables et schémas du millésime 2025.
    older = Payload.new("liasse", %w[2035], SchemaSpec.identity, "2024-01-01", "2024-12-31",
      boxes: {"2035-B" => Formats.zone_codes("2035-B", 202501).to_h { |code| {code, "1"} }})
    (Formats.liasse_zones(older) || raise "zones absentes").each do |form, values|
      store.check_block(form, JSON.parse(values.to_json), Formats.millesime_target(older)).violations.should be_empty
    end
    # Sans le suffixe, les cases de la 2035 seraient refusées par le schéma.
    unsuffixed = JSON.parse({"FJ" => 1}.to_json)
    store.check_block("2035", unsuffixed, 202601).violations.map(&.to_s).should eq(["$.zones_formulaires.2035.FJ : unknown"])
  end

  it "fait valider par l'adaptateur réel, avant l'envoi, chaque dépôt préparé par l'extension" do
    store = SchemaSpec.store!
    S.books
    S.connect
    S.teledec.schemas = store
    Books.sale(Books.card("CUSTOMER", "Client 1000").code, "1000", "2026-03-10")
    created = Acc.create_vat_return(S::SYSTEM, Acc::VatReturnInput.new(form: "fr_ca3", year: 2026, periodicity: "month", number: 3)).value!
    ca3 = Acc.close_vat_return(S::SYSTEM, (created.id || raise("déclaration sans identifiant")), nil).value!
    lawyer = S.supplier("Cabinet Durand")
    S.fees(lawyer, "1010", "2026-02-10")
    # Préparé puis transmis un à un : le solde d'IS reprend les acomptes
    # transmis.
    inputs = [
      Api::PrepareInput.new(kind: "vat_ca3", vat_return_id: ca3.id),
      Api::PrepareInput.new(kind: "das2", year: 2026),
      Api::PrepareInput.new(kind: "is_2571", fiscal_year_id: S.fiscal_year_id, number: 2, amount: BigDecimal.new(2500)),
      Api::PrepareInput.new(kind: "is_2572", fiscal_year_id: S.fiscal_year_id, amount: BigDecimal.new(9000)),
      Api::PrepareInput.new(kind: "liasse", fiscal_year_id: S.fiscal_year_id),
    ]
    inputs.each { |input| Api.transmit(S.admin, Api.prepare(S.admin, input).value!.id).value! }
    bodies = S.teledec.requests.select(&.path.==("/service/declaration-marque-blanche")).map { |request| JSON.parse(request.body) }
    bodies.size.should eq(4)
    bodies.each do |document|
      form = (document.as_h.keys - %w[auth identity period]).first
      kind = Formats.kind_of_form(form) || raise "formulaire inattendu #{form}"
      period = document["period"]
      target = Remote::Millesime.target(kind, period["end"].as_s, period["echeance"]?.try(&.as_s))
      store.check_document(document, form, target).violations.should be_empty
    end
    S.teledec.requests.map(&.path).should contain("/service/liasse")
  end

  it "fait valider la 2035 préparée par le module liberal (cases jointes à la liasse)" do
    SchemaSpec.store!
    S.liberal_books
    S.connect
    S.liberal_line("receipt", "2026-03-03", "42000", "RECEIPTS")
    S.liberal_line("expense", "2026-03-04", "9600", "RENT")
    Partiduo::Api::Liberal.close_year(S::SYSTEM, 2026).value!
    S.teledec.schemas = Remote::Schemas.new(SchemaSpec::DIR)
    actor = S.admin(S::LIBERAL)
    filing = Api.prepare(actor, Api::PrepareInput.new(kind: "liasse", fiscal_year_id: S.fiscal_year_id)).value!
    filing.ready?.should be_true
    Api.transmit(actor, filing.id).value!
    body = S.teledec.requests.find! { |request| request.path == "/service/liasse" }.body
    body.lines.should contain("#MILLESIME 2027")
    zones = S::LiasseBody.parse(body).zones
    zones["2035A"]["AA"].as_i.should eq(42000)
  end

  it "fait valider par les schémas 2035A et 2035B la section JSON de la 2035 sans balance, telle qu'envoyée (D-TDC7-001)" do
    store = SchemaSpec.store!
    body = S.liberal_2035_body(2025)
    zones = S::LiasseBody.parse(body).zones.as_h
    zones.keys.sort!.should eq(%w[2035A 2035B])
    zones.each do |form, block|
      outcome = store.check_block(form, block, 202601)
      {form, outcome.schema_name, outcome.violations.map(&.to_s)}.should eq({form, "#{form}-2026", [] of String})
    end
    # Bloc de la 2035 elle-même (cases suffixées) : même schéma que l'envoi.
    zones2035 = Formats.liasse_zones(Payload.new("liasse", %w[2035], SchemaSpec.identity, "2025-01-01", "2025-12-31",
      boxes: {"2035" => {"FJ" => "120"}})) || raise "zones absentes"
    store.check_block("2035", JSON.parse(zones2035["2035"].to_json), 202601).violations.should be_empty
  end
end
