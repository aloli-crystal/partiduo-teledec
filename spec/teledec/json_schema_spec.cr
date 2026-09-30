# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias JsonSchema = Teledec::Remote::JsonSchema

# Schéma réduit, à la manière de ceux de TELEDEC (enveloppe et bloc de
# formulaire fermé).
private SCHEMA = JSON.parse(<<-JSON)
  {
    "$schema": "http://json-schema.org/draft-07/schema#",
    "title": "API TELEDEC - essai",
    "type": "object",
    "required": ["auth", "period", "DAS2"],
    "additionalProperties": true,
    "x-teledec-note": "structure seule",
    "properties": {
      "auth": {"type": "object", "required": ["email"], "properties": {
        "email": {"type": "string", "format": "email"},
        "timestamp": {"type": "string", "format": "date-time"}}},
      "identity": {"type": "object", "properties": {
        "siret": {"type": "string", "minLength": 9},
        "yearEndMonth": {"type": "integer", "minimum": 1, "maximum": 12}}},
      "period": {"type": "object", "required": ["end"], "properties": {
        "end": {"type": "string", "format": "date"},
        "millesime": {"type": "integer"}}},
      "DAS2": {"type": "object", "additionalProperties": false, "properties": {
        "AE": {"type": "string"},
        "TB": {"type": "integer"},
        "HE": {"type": "number", "x-teledec-precision": 2},
        "SD": {"type": "boolean"},
        "repetitionDAS2TV": {"type": "array", "items": {"type": "object", "additionalProperties": false,
          "properties": {"AI": {"type": "string", "format": "date"}, "BA": {"type": "integer"}}}}}}
    }
  }
  JSON

private def violations(document : String) : Array(String)
  JsonSchema.validate(SCHEMA, JSON.parse(document)).map(&.to_s)
end

describe "Validation par schéma JSON (sous-ensemble des schémas de TELEDEC, D-TDC6-002)" do
  it "accepte un document conforme" do
    violations(<<-JSON).should be_empty
      {"auth": {"email": "a@b.fr", "timestamp": "2026-09-30T10:00:00"}, "identity": {"siret": "732829320", "yearEndMonth": 12},
       "period": {"end": "2025-12-31", "millesime": 2026}, "autre": 1,
       "DAS2": {"AE": "73282932000074", "TB": 0, "HE": 12.5, "SD": true, "repetitionDAS2TV": [{"AI": "1980-05-14", "BA": 1200}]}}
      JSON
  end

  it "signale chaque écart avec le chemin JSON de la valeur" do
    violations(<<-JSON).should eq([
      {"auth": {"email": "pas-une-adresse", "timestamp": "30/09/2026"}, "identity": {"siret": "7328", "yearEndMonth": 13},
       "period": {"millesime": "2026"},
       "DAS2": {"AE": 732829320, "TB": 1.5, "ZZ": 1, "repetitionDAS2TV": [{"AI": "1980-02-30", "BA": "1200", "X": 0}]}}
      JSON
      "$.auth.email : format expected=email",
      "$.auth.timestamp : format expected=date-time",
      "$.identity.siret : min_length limit=9",
      "$.identity.yearEndMonth : maximum limit=12",
      "$.period.end : required",
      "$.period.millesime : type expected=integer actual=string",
      "$.DAS2.AE : type expected=string actual=integer",
      "$.DAS2.TB : type expected=integer actual=number",
      "$.DAS2.ZZ : unknown",
      "$.DAS2.repetitionDAS2TV[0].AI : format expected=date",
      "$.DAS2.repetitionDAS2TV[0].BA : type expected=integer actual=string",
      "$.DAS2.repetitionDAS2TV[0].X : unknown",
    ])
  end

  it "exige les blocs obligatoires et le type de la racine" do
    violations(%({"auth": {"email": "a@b.fr"}})).should eq(["$.period : required", "$.DAS2 : required"])
    violations(%([1])).should eq(["$ : type expected=object actual=array"])
  end

  it "admet un entier écrit 12.0, un horodatage avec décalage, et nomme une clé non identifiant entre crochets" do
    JsonSchema.type?("integer", JSON.parse("12.0")).should be_true
    JsonSchema.type?("number", JSON.parse("12")).should be_true
    JsonSchema.format?("date-time", "2026-09-30T10:00:00.123+02:00").should be_true
    JsonSchema.format?("date-time", "2026-09-30 10:00:00").should be_false
    JsonSchema.format?("date", "2024-02-29").should be_true
    JsonSchema.format?("date", "2025-02-29").should be_false
    JsonSchema.format?("uri", "n'importe quoi").should be_true # format non contrôlé
    JsonSchema.child("$.DAS2", "a b").should eq(%($.DAS2["a b"]))
  end

  it "interprète enum, const, pattern, maxLength, bornes exclusives, minItems, maxItems et schémas booléens" do
    schema = JSON.parse(<<-JSON)
      {"type": "object", "additionalProperties": false, "properties": {
        "code": {"type": "string", "enum": ["H", "C"], "pattern": "^[A-Z]$", "maxLength": 1},
        "fixe": {"const": 1},
        "taux": {"type": ["number", "null"], "exclusiveMinimum": 0, "exclusiveMaximum": 100},
        "liste": {"type": "array", "minItems": 1, "maxItems": 2, "items": [{"type": "string"}]},
        "libre": true}}
      JSON
    ok = JSON.parse(%({"code": "H", "fixe": 1, "taux": null, "liste": ["a", 2], "libre": {"x": 1}}))
    JsonSchema.validate(schema, ok).should be_empty
    bad = JSON.parse(%({"code": "hh", "fixe": 2, "taux": 100, "liste": [1, 2, 3]}))
    JsonSchema.validate(schema, bad).map(&.code).should eq(%w[enum max_length pattern enum maximum max_items type])
  end

  it "liste les mots-clés qu'il n'interprète pas, hors annotations" do
    JsonSchema.unsupported(SCHEMA).should be_empty
    JsonSchema.unsupported(JSON.parse(%({"type": "object", "properties": {"a": {"anyOf": [], "$ref": "#"}}})))
      .should eq(["$ref", "anyOf"])
  end

  it "traduit chaque code d'écart en fr, en et nl" do
    %w[type required unknown format minimum maximum min_length max_length enum pattern min_items max_items more].each do |code|
      Partiduo::LOCALES.each do |locale|
        I18n.with_locale(locale) { I18n.t("teledec.schema.#{code}").should_not contain("missing") }
      end
    end
  end
end
