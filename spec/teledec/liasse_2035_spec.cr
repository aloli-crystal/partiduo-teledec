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
