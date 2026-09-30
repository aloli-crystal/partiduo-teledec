# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Teledec::SpecSupport
private alias Formats = Teledec::Remote::Formats
private alias Payload = Teledec::Payload

# Codes des zones numériques des formulaires 2035, 2035A et 2035B de
# TELEDEC, millésime 2026 (feuilles « Champs » et « Template » relevées dans
# `partiduo/.teledec-doc/FORMULAIRES-TELEDEC.adoc`, B-TDC-004) : la table de
# correspondance livrée par le module `liberal` ne doit reporter qu'à ces
# cases (DECISIONS D-VAL-006).
private TELEDEC_2035_CODES = {
  "2035-A" => %w[
    AA AB AC AD AE AF AG BA BB BC BD BE BF BG BH BJ BK BL BM BN BP BR BS BT BU BV EA EB EC ED EE EF EG EJ EK EL EM EN
    FC GF GJ GL AW
  ],
  "2035-B" => %w[
    CA CB CC CD CE CF CG CH CK CL CM CN CP CR CS CT CX CY CZ DG AF AD AE DJ DK AC DL AG DM GK HC HE JA AB DP DQ DR DS
  ],
  "2035" => %w[AA AB FG FH FJ FV MG NG NH NN NP NQ NR AP AL AM AJ AN AF AR AG AH AS],
}

private def identity : Payload::Identity
  Payload::Identity.new("Cabinet Martin", "", "732829320", "", "", "", "12 rue des Arts", "69002", "Lyon", "FR",
    "contact@cabinet-martin.test")
end

describe "2035 transmise à TELEDEC (module liberal, B-TDC-004)" do
  it "ne reporte qu'à des cases connues des formulaires 2035 de TELEDEC" do
    S.books("bnc", "none")
    Partiduo::Api::Modules.activate(S::SYSTEM, "LIBERAL").value!
    Partiduo::Api::Liberal.load_defaults(S::SYSTEM)
    lines = Partiduo::Api::Liberal.form_lines(S::SYSTEM, 2026).reject(&.box.empty?)
    lines.size.should be > 50
    lines.each do |line|
      {line.item, line.form, TELEDEC_2035_CODES[line.form].includes?(line.box)}.should eq({line.item, line.form, true})
    end
    # Aucune case reçue par deux postes d'un même formulaire.
    lines.group_by { |line| {line.form, line.box} }.select { |_, same| same.size > 1 }.keys.should be_empty
  end

  it "nomme les zones de la 2035-A et de la 2035-B par le code seul, celles de la 2035 suffixées (schéma de TELEDEC)" do
    boxes = {"2035-A" => {"EB" => "120.40", "BH" => "120.40"}, "2035-B" => {"CP" => "999.50"}, "2035" => {"FJ" => "10"}}
    payload = Payload.new("liasse", %w[2035], identity, "2026-01-01", "2026-12-31", boxes: boxes)
    zones = Formats.liasse_zones(payload) || raise "zones de la liasse absentes"
    zones["2035A"].should eq({"EB" => 120_i64, "BH" => 120_i64})
    zones["2035B"].should eq({"CP" => 1000_i64})
    zones["2035"].should eq({"FJ_2035" => 10_i64})
  end

  it "reprend dans l'adaptateur le schéma relevé des formulaires 2035 de TELEDEC, par millésime" do
    # Millésime 2026 (exercice 2025) : la 2035-B n'a plus DM.
    TELEDEC_2035_CODES.each do |form, codes|
      Formats.zone_codes(form, 202601).sort.should eq((codes - (form == "2035-B" ? %w[DM] : [] of String)).sort)
    end
    union = Formats::ZONE_CODES.transform_values(&.values.flatten.uniq!.sort!)
    union.should eq(TELEDEC_2035_CODES.transform_values(&.sort))
  end
end

# Liasse sans balance (D-TDC7-001) : le stage a répondu « Misformatted JSON »
# à la 2035 d'un libéral sans Comptabilité, dont la section JSON suivait
# l'identification sur une seule ligne. Le corps suit désormais la forme
# documentée de l'API Balance, vérifiée ici hors ligne.
describe "2035 sans balance transmise à TELEDEC (D-TDC7-001)" do
  it "envoie l'identification, aucune section de balance, puis une section JSON valide sur plusieurs lignes" do
    body = S.liberal_2035_body(2025)
    sections = S::LiasseBody.parse(body)
    sections.header.all?(&.matches?(/\A#[A-Z-]+ \S/)).should be_true
    sections.header.should contain("#CATEGORIE-FISCALE BNC")
    sections.header.should contain("#EXERCICE-DATE-FIN 20251231")
    sections.header.should contain("#MILLESIME 2026")
    # Ni ligne de balance, ni ligne vide, ni ligne d'en-tête de balance.
    sections.balance.should be_empty
    body.lines.none?(&.strip.empty?).should be_true
    body.lines.none?(&.includes?(';')).should be_true
    # Section JSON : `{` seul sur sa ligne, `}` seul sur la dernière, rien après.
    json = sections.json || raise "section JSON absente"
    json.lines.first.should eq("{")
    json.lines.last.should eq("}")
    body.should end_with("}\n")
    document = sections.document
    document.as_h.keys.sort!.should eq(%w[informations_supplementaires zones_formulaires])
    document["informations_supplementaires"].as_h.should be_empty
    zones = sections.zones.as_h
    zones.keys.sort!.should eq(%w[2035A 2035B])
    zones.each_value { |block| block.as_h.each_value(&.as_i64) }
    zones["2035A"]["AA"].as_i64.should eq(42000)
    zones["2035B"]["CP"].as_i64.should eq(31550)
  end

  it "place la section JSON après la dernière ligne de balance, et n'en écrit aucune sans case" do
    identity = Payload::Identity.new("Cabinet Martin", "EI", "732829320", "", "", "", "12 rue des Arts", "69002", "Lyon",
      "FR", "contact@cabinet-martin.test")
    credentials = Teledec::Credentials.new("login", "secret", "sandbox", "compta@exemple.test", "73282932000074",
      password_hash: "$2a$12$empreinte")
    submission = Teledec::Submission.new("partiduo-1-1-abcdef", "liasse", %w[2035], "{}", "abcdef")
    rows = [Payload::BalanceRow.new("706", "Honoraires", "0.00", "42000.00", "0.00", "42000.00")]
    boxes = {"2035-A" => {"AA" => "42000"}}
    with_both = Payload.new("liasse", %w[2035], identity, "2025-01-01", "2025-12-31", balance: rows, boxes: boxes)
    sections = S::LiasseBody.parse(Formats.liasse(with_both, submission, credentials, "API", false, "compte@exemple.test"))
    sections.balance.should eq(["706;Honoraires;0;0;0.00;42000.00;0.00;42000.00"])
    sections.zones["2035A"]["AA"].as_i64.should eq(42000)
    bare = Payload.new("liasse", %w[2035], identity, "2025-01-01", "2025-12-31")
    Formats.liasse_json(bare).should be_nil
    sections = S::LiasseBody.parse(Formats.liasse(bare, submission, credentials, "API", false, "compte@exemple.test"))
    {sections.balance, sections.json}.should eq({[] of String, nil})
  end
end
