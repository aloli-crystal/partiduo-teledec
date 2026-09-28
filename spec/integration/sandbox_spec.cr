# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"
require "crypto/bcrypt/password"

# Suite d'intégration contre l'environnement de test (stage) de TELEDEC,
# par l'adaptateur réel (`Teledec::HttpTransport`) : jeton, création d'une
# entreprise de test, liasse d'une balance de démonstration (URL rendue),
# TVA en marque blanche, suivi. Activée seulement si
# `~/.config/partiduo/teledec-sandbox.env` porte `TELEDEC_SANDBOX_CLIENT_ID`
# et `TELEDEC_SANDBOX_CLIENT_SECRET` ; ces valeurs ne sont jamais affichées,
# journalisées ni copiées. Tout part sur le stage (`sandbox`) : rien n'est
# transmis à la DGFiP, et la liasse est envoyée sans bouton « Envoyer ».
module Teledec::SandboxSpec
  FILE = File.join(ENV["HOME"]? || "/nonexistent", ".config/partiduo/teledec-sandbox.env")
  # Entreprise fictive (SIREN à clé valide, non attribué à notre
  # connaissance) et compte de test sur un domaine réservé.
  EMAIL = "partiduo-stage@example.org"
  SIREN = "999888779"
  SIRET = "99988877900017"

  def self.values : Hash(String, String)?
    return unless File.exists?(FILE)
    values = {} of String => String
    File.each_line(FILE) do |line|
      name, sep, value = line.strip.lchop("export ").partition('=')
      next if sep.empty? || name.starts_with?('#')
      values[name.strip] = value.strip.strip('"').strip('\'')
    end
    values if values["TELEDEC_SANDBOX_CLIENT_ID"]?.presence && values["TELEDEC_SANDBOX_CLIENT_SECRET"]?.presence
  rescue File::Error
    nil
  end

  def self.credentials(secret : String? = nil) : Credentials
    found = values || raise "identifiants du stage absents"
    Credentials.new(found["TELEDEC_SANDBOX_CLIENT_ID"], secret || found["TELEDEC_SANDBOX_CLIENT_SECRET"], "sandbox", EMAIL, SIRET)
  end

  def self.transport : HttpTransport
    HttpTransport.new(Remote::Net.new, send_button: false)
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

  def self.identity : Payload::Identity
    Payload::Identity.new("PARTIDUO ESSAI", "SAS", SIREN, "", "", "1000.00", "3 rue des Lilas", "69003", "Lyon",
      "FR", EMAIL)
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

  def self.ca3_payload : Payload
    boxes = {"3310-CA3" => {"A1" => "1000", "08.base" => "1000", "08.tax" => "200", "16" => "200", "20" => "50",
                            "23" => "50", "28" => "150", "32" => "150"}}
    Payload.new("vat_ca3", ["3310-CA3"], identity, "2026-08-01", "2026-08-31", 8, nil, nil, boxes, nil,
      {"periodicity" => "month"})
  end

  def self.submission(payload : Payload, due_on : String? = nil) : Submission
    json = payload.to_json
    Submission.new("partiduo-stage-#{Time.utc.to_unix}", payload.kind, payload.forms, json, payload.fingerprint,
      due_on: due_on, year_end: "2025-12-31")
  end
end

describe "Stage de TELEDEC (intégration, optionnelle)" do
  if Teledec::SandboxSpec.values
    it "vise le stage, jamais la production" do
      Teledec::SandboxSpec.credentials.env.should eq("sandbox")
      Teledec::HttpTransport::API_URLS["sandbox"].should eq("https://stage.teledec.fr")
    end

    it "obtient un jeton, et refuse un secret faux" do
      Teledec::SandboxSpec.require_stage!
      transport = Teledec::SandboxSpec.transport
      transport.check(Teledec::SandboxSpec.credentials)
      error = expect_raises(Teledec::TransportError) do
        transport.check(Teledec::SandboxSpec.credentials("secret-faux"))
      end
      error.key.should eq("teledec.errors.transport.credentials")
    end

    it "crée l'entreprise de test et la rattache au compte" do
      Teledec::SandboxSpec.require_stage!
      password = Crypto::Bcrypt::Password.create(Random::Secure.hex(16), cost: 12).to_s
      identity = {"siren" => Teledec::SandboxSpec::SIREN, "name" => "PARTIDUO ESSAI", "yearEndMonth" => 12,
                  "yearEndDay" => 31, "addressStreet" => "3 rue des Lilas", "addressPostalCode" => "69003",
                  "addressCity" => "Lyon", "addressCountry" => "FR", "legalForm" => "SAS",
                  "fullRegimeFiscal" => "ISRS", "regimeFiscalTVA" => "Normal"} of String => String | Int32
      answer = Teledec::SandboxSpec.transport.create_company(Teledec::SandboxSpec.credentials, identity, password)
      answer.should contain(Teledec::SandboxSpec::EMAIL)
    end

    it "envoie la liasse d'une balance de démonstration (URL rendue), ou signale la source non reconnue" do
      Teledec::SandboxSpec.require_stage!
      transport = Teledec::SandboxSpec.transport
      submission = Teledec::SandboxSpec.submission(Teledec::SandboxSpec.liasse_payload)
      if ENV["PARTIDUO_TELEDEC_SOURCE"]?.presence
        submitted = transport.submit(Teledec::SandboxSpec.credentials, submission)
        submitted.url.should start_with("https://stage.teledec.fr")
        submitted.remote_id.should eq("liasse:#{Teledec::SandboxSpec::SIREN}:2025-12-31")
      else
        # Nom de partenaire attendu par TELEDEC dans `#SOURCE` non
        # communiqué (BLOCAGES B-TDC-004) : TELEDEC refuse la liasse.
        error = expect_raises(Teledec::TransportError) do
          transport.submit(Teledec::SandboxSpec.credentials, submission)
        end
        error.key.should eq("teledec.errors.transport.source")
      end
      status = transport.status(Teledec::SandboxSpec.credentials, "liasse:#{Teledec::SandboxSpec::SIREN}:2025-12-31")
      status.state.should eq("pending")
    end

    it "dépose une CA3 en marque blanche (lien rendu), puis en relève l'état" do
      Teledec::SandboxSpec.require_stage!
      transport = Teledec::SandboxSpec.transport
      submission = Teledec::SandboxSpec.submission(Teledec::SandboxSpec.ca3_payload, due_on: "2026-09-19")
      submitted = transport.submit(Teledec::SandboxSpec.credentials, submission)
      submitted.remote_id.should eq("3310CA3:#{Teledec::SandboxSpec::SIREN}:2026-08-31:2026-09-19")
      submitted.url.should start_with("https://stage.teledec.fr/")
      status = transport.status(Teledec::SandboxSpec.credentials, submitted.remote_id)
      status.state.should eq("pending")
      status.remote_status.should eq("readytobesent")
    end
  else
    pending "identifiants du stage absents (~/.config/partiduo/teledec-sandbox.env)"
  end
end
