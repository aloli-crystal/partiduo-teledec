# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Formats = Teledec::Remote::Formats
private alias Payload = Teledec::Payload

private def identity(legal_form : String = "SARL", siren : String = "732829320", street : String = "12 rue des Arts") : Payload::Identity
  Payload::Identity.new("Atelier Brunet SARL", legal_form, siren, "FR44732829320", "Lyon B 732 829 320", "10000",
    street, "69002", "Lyon", "FR", "contact@atelier-brunet.test")
end

private def credentials(email : String = "compta@atelier-brunet.test", siret : String = "73282932000074") : Teledec::Credentials
  Teledec::Credentials.new("login", "secret", "sandbox", email, siret)
end

private def submission(kind : String, due_on : String? = nil, year_end : String? = nil,
                       callback_url : String? = nil) : Teledec::Submission
  Teledec::Submission.new("partiduo-1-1-abcdef", kind, [] of String, "{}", "abcdef", due_on: due_on,
    year_end: year_end, callback_url: callback_url)
end

private def vat(kind : String, boxes : Hash(String, String), from : String = "2026-03-01", to : String = "2026-03-31",
                periodicity : String = "month") : Payload
  form = kind == "vat_ca3" ? "3310-CA3" : "3517-S-CA12"
  Payload.new(kind, [form], identity, from, to, boxes: {form => boxes}, details: {"periodicity" => periodicity})
end

# Document marque blanche produit pour `payload` (horodatage fixé).
private def white_label(payload : Payload, sub : Teledec::Submission = submission(payload.kind),
                        creds : Teledec::Credentials = credentials) : JSON::Any
  JSON.parse(Formats.white_label(payload, sub, creds, Time.utc(2026, 7, 1, 22, 30)))
end

describe "Formats de l'API partenaire de TELEDEC (unitaires)" do
  describe "montants" do
    it "arrondit à l'euro le plus proche, 0,50 à l'euro supérieur (aussi pour un montant négatif)" do
      Formats.integer("1234.49").should eq(1234)
      Formats.integer("1234.50").should eq(1235)
      Formats.integer("-10.50").should eq(-11)
      Formats.integer("0.49").should eq(0)
      Formats.integer("illisible").should eq(0)
    end
  end

  describe "identification" do
    it "traduit la forme juridique, sans tenir compte de la ponctuation ni de la casse ; inconnue : ZZZ" do
      Formats.legal_form("SARL").should eq("SRL")
      Formats.legal_form("s.a.s.").should eq("SAS")
      Formats.legal_form(" Selarl ").should eq("SLR")
      Formats.legal_form("Société coopérative").should eq("ZZZ")
      Formats.legal_form("").should be_nil
      Formats.legal_form(" - ").should be_nil
    end

    it "ne transmet que le SIRET complet de l'entreprise déclarante" do
      Formats.siret(credentials(siret: "732 829 320 00074"), identity).should eq("73282932000074")
      Formats.siret(credentials(siret: "40483304800006"), identity).should be_nil # autre SIREN
      Formats.siret(credentials(siret: "7328293200007"), identity).should be_nil  # 13 chiffres
      Formats.siret(credentials(siret: ""), identity).should be_nil
      Formats.siret(credentials(siret: "40483304800006"), identity(siren: "")).should eq("40483304800006")
    end

    it "retire les fins de ligne et points-virgules des valeurs de la liasse" do
      Formats.clean("Frais;divers\r\nsuite ;").should eq("Frais divers suite")
      Formats.compact_day("2026-12-31").should eq("20261231")
    end
  end

  describe "identifiant de suivi" do
    it "porte l'échéance pour la TVA et l'acompte d'IS, pas pour la liasse, la DAS2 ni le solde d'IS" do
      Formats.key(vat("vat_ca3", {"08.base" => "1"}), "2026-04-19").to_s.should eq("3310CA3:732829320:2026-03-31:2026-04-19")
      Formats.key(vat("vat_ca12", {"08.base" => "1"}, "2026-01-01", "2026-12-31"), "2027-05-05").to_s
        .should eq("3517SCA12:732829320:2026-12-31:2027-05-05")
      liasse = Payload.new("liasse", %w[2065 2033], identity, "2026-01-01", "2026-12-31")
      Formats.key(liasse, "2027-05-05").to_s.should eq("liasse:732829320:2026-12-31")
      solde = Payload.new("is_2572", %w[2572], identity, "2026-01-01", "2026-12-31")
      Formats.key(solde, "2027-05-15").to_s.should eq("2572:732829320:2026-12-31")
      advance = Payload.new("is_2571", %w[2571], identity, "2026-01-01", "2026-12-31", number: 1)
      Formats.key(advance, "2026-03-15").to_s.should eq("2571:732829320:2026-12-31:2026-03-15")
    end

    it "refuse un identifiant sans SIREN à neuf chiffres ou au nombre de parties inattendu" do
      Formats::Key.parse("liasse:73282932:2026-12-31").should be_nil
      Formats::Key.parse("liasse:732829320").should be_nil
      Formats::Key.parse("a:732829320:b:c:d").should be_nil
      key = Formats::Key.parse("2571:732829320:2026-12-31:2026-03-15") || raise "clé illisible"
      key.echeance.should eq("2026-03-15")
      (Formats::Key.parse("2571:732829320:2026-12-31:") || raise "clé illisible").echeance.should be_nil
    end
  end

  describe "tables de codes" do
    it "prend la table du millésime le plus récent applicable, la plus ancienne avant la première" do
      Formats.codes("3310CA3", 2030)["08.base"].should eq("FP")
      Formats.codes("3310CA3", 2020)["08.base"].should eq("FP")
      Formats.codes("3517SCA12", 2026)["08.base"].should eq("EW")
    end

    it "ignore les cases nulles, les totaux repris ailleurs et les sortes hors TVA" do
      Formats.unmapped("vat_ca3", {"14.base" => "0.00", "A1" => "10"}, 2026).should be_empty
      Formats.unmapped("vat_ca12", {"A1" => "1000", "08.base" => "1000"}, 2026).should be_empty
      Formats.unmapped("vat_ca12", {"14.tax" => "3", "A2" => "1"}, 2026).should eq(["14.tax", "A2"])
      Formats.unmapped("liasse", {"zz" => "1"}, 2026).should be_empty
      Formats.unmapped("inconnue", {"zz" => "1"}, 2026).should be_empty
    end
  end

  describe "marque blanche" do
    it "horodate en heure française et reprend la fin d'exercice, l'échéance et l'adresse des rappels" do
      payload = vat("vat_ca3", {"08.base" => "1000", "08.tax" => "200", "16" => "200", "28" => "200", "32" => "200.40"})
      document = white_label(payload, submission("vat_ca3", "2026-04-19", "2026-06-30", "https://x.test/hooks/TELEDEC/callback?token=t"))
      document["auth"]["timestamp"].as_s.should eq("2026-07-02T00:30:00") # UTC+2 en été
      document["auth"]["url"].as_s.should eq("https://x.test/hooks/TELEDEC/callback?token=t")
      document["auth"]["bloquerSiIncoherence"].as_bool.should be_false
      document["identity"]["yearEndMonth"].as_i.should eq(6)
      document["identity"]["yearEndDay"].as_i.should eq(30)
      document["identity"]["legalForm"].as_s.should eq("SRL")
      document["identity"]["addressPostalCode"].as_s.should eq("69002")
      document["period"]["reference"].as_s.should eq("partiduo-1-1-abcdef")
      document["period"]["montant"].as_i.should eq(200)
      document["period"]["noPayment"].as_bool.should be_false
      document["3310CA3"]["KE"].as_i.should eq(200)
      document["3310CA3"]["KF"]?.should be_nil
    end

    it "sans échéance ni fin d'exercice ni adresse de rappel : fin d'exercice au 31 décembre, champs omis" do
      document = white_label(vat("vat_ca3", {"08.base" => "10", "08.tax" => "2"}), submission("vat_ca3"))
      document["auth"]["url"]?.should be_nil
      document["period"]["echeance"]?.should be_nil
      document["identity"]["yearEndMonth"].as_i.should eq(12)
      document["identity"]["yearEndDay"].as_i.should eq(31)
      document["auth"]["timestamp"].as_s.should eq("2026-07-02T00:30:00")
    end

    it "horodate en heure d'hiver hors de l'été" do
      payload = vat("vat_ca3", {"08.base" => "10"})
      document = JSON.parse(Formats.white_label(payload, submission("vat_ca3"), credentials, Time.utc(2026, 12, 1, 8, 0)))
      document["auth"]["timestamp"].as_s.should eq("2026-12-01T09:00:00")
    end

    it "dépose une CA3 néant (KF) sans paiement, et une CA3 trimestrielle au régime NormalTrimestriel" do
      document = white_label(vat("vat_ca3", {"08.base" => "0.00", "32" => "0.40"}, periodicity: "quarter"))
      document["3310CA3"].as_h.should eq({"KF" => JSON::Any.new(true)})
      document["period"]["montant"].as_i.should eq(0)
      document["period"]["noPayment"].as_bool.should be_true
      document["identity"]["regimeFiscalTVA"].as_s.should eq("NormalTrimestriel")
    end

    it "ne transmet pas les cases sans code et arrondit chaque case à l'euro" do
      block = white_label(vat("vat_ca3", {"08.base" => "999.50", "08.tax" => "199.90", "14.base" => "50"}))["3310CA3"].as_h
      block["FP"].as_i.should eq(1000)
      block["GP"].as_i.should eq(200)
      # Totaux recalculés : 16 (GH), 28 (KA), 32 (KE).
      block.keys.sort!.should eq(%w[FP GH GP KA KE])
      block["KE"].as_i.should eq(200)
    end

    it "recalcule les totaux de la CA3 sur les cases arrondies (100 + 100 = 200, pas 201)" do
      boxes = {"08.tax" => "100.40", "09.tax" => "100.40", "16" => "200.80", "20" => "50.40", "23" => "50.40",
               "28" => "150.40", "32" => "150.40"}
      document = white_label(vat("vat_ca3", boxes))
      block = document["3310CA3"].as_h
      {block["GP"], block["GB"], block["GH"], block["HB"], block["HG"], block["KA"], block["KE"]}.map(&.as_i)
        .should eq({100, 100, 200, 50, 50, 150, 150})
      document["period"]["montant"].as_i.should eq(150)
      credit = white_label(vat("vat_ca3", {"08.tax" => "10.40", "20" => "30.60", "26" => "5"}))["3310CA3"].as_h
      {credit["JA"], credit["JB"], credit["JC"]}.map(&.as_i).should eq({21, 5, 16})
      credit.has_key?("KE").should be_false
    end

    it "garde des totaux cohérents à la préparation (VatTotals)" do
      Teledec::VatTotals.coherent("vat_ca3", {"08.tax" => "100.40", "09.tax" => "100.40", "16" => "200.80", "A1" => "0.40"})
        .should eq({"08.tax" => "100", "09.tax" => "100", "16" => "200", "28" => "200", "32" => "200"})
      Teledec::VatTotals.coherent("vat_ca12", {"08.tax" => "1000", "20" => "400", "ac" => "900.50"})
        .should eq({"08.tax" => "1000", "20" => "400", "ac" => "901", "16" => "1000", "23" => "400", "28" => "600",
                    "ex" => "301"})
      Teledec::VatTotals.coherent("das2", {"x" => "1.50", "y" => "0.20"}).should eq({"x" => "2"})
    end

    it "met la CA12 au formulaire 3517SCA12 : régime simplifié, solde à payer (SC), néant (SD)" do
      payload = vat("vat_ca12", {"A1" => "5000", "08.base" => "5000", "08.tax" => "1000", "16" => "1000", "sp" => "600",
                                 "20" => "400", "ac" => "400"}, "2026-01-01", "2026-12-31", "year")
      document = white_label(payload, submission("vat_ca12", "2027-05-05"))
      block = document["3517SCA12"].as_h
      block["EW"].as_i.should eq(5000)
      block["FW"].as_i.should eq(1000)
      # Solde recalculé : 1 000 − 400 déductibles − 400 d'acomptes.
      block["SC"].as_i.should eq(200)
      block["NA"].as_i.should eq(200)
      block["LA"].as_i.should eq(600)
      block["HC"].as_i.should eq(400)
      block["MM"].as_i.should eq(400)
      block.has_key?("A1").should be_false
      document["identity"]["regimeFiscalTVA"].as_s.should eq("Simplifie")
      document["period"]["montant"].as_i.should eq(200)
      nothing = white_label(vat("vat_ca12", {"A1" => "0"}, "2026-01-01", "2026-12-31", "year"))
      nothing["3517SCA12"].as_h.should eq({"SD" => JSON::Any.new(true)})
    end

    it "met un excédent d'acomptes d'IS en créance (2572), sans montant à payer" do
      payload = Payload.new("is_2572", %w[2572], identity, "2026-01-01", "2026-12-31",
        details: {"tax" => "3000.40", "advances" => "5000"})
      document = white_label(payload)
      block = document["2572"]
      block["GE"].as_i.should eq(3000)
      block["RT"].as_i.should eq(5000)
      block["PN"].as_i.should eq(0)
      block["PQ"].as_i.should eq(2000)
      block["DA"].as_i.should eq(2000)
      document["period"]["montant"].as_i.should eq(0)
      document["period"]["noPayment"].as_bool.should be_true
      document["identity"]["regimeFiscalTVA"]?.should be_nil
    end

    it "ventile la DAS2 par nature (lettres de la DGFiP) et totalise par nature" do
      lines = [
        Payload::Das2Line.new("F1", "Cabinet Durand", "40483304800006", "Avocat", "3 rue des Lilas", "69003", "Lyon", "FR",
          {"fees" => "1500", "commissions" => "0", "rebates" => "300.50"}, "1800.50"),
        Payload::Das2Line.new("F2", "Agence Martin", "", "", "", "", "", "FR", {"fees" => "700", "other" => "90"}, "790"),
      ]
      payload = Payload.new("das2", %w[DAS2], identity(street: ""), "2026-01-01", "2026-12-31", das2: lines)
      block = white_label(payload)["DAS2"]
      block["AE"].as_s.should eq("73282932000074")
      block["AA_3042_1"]?.should be_nil
      block["AA_3251_1"].as_s.should eq("69002")
      repetitions = block["repetitionDAS2TV"].as_a
      repetitions.map { |item| {item["CA"].as_s, item["BA"].as_i} }.should eq([{"H", 1500}, {"R", 301}, {"H", 700}, {"V", 90}])
      repetitions[2]["AF_3039_1"]?.should be_nil
      repetitions[2]["AG_3251_1"]?.should be_nil
      repetitions[0]["AH_4440_1"].as_s.should eq("Avocat")
      repetitions.map(&.["AD"].as_s).uniq!.should eq(["73282932000074"])
      totals = block["repetitionDAS2TotauxSommesVersees"].as_a.to_h { |item| {item["UA"].as_s, item["TA"].as_i} }
      totals.should eq({"H" => 2200, "R" => 301, "V" => 90})
    end

    it "refuse une nature de DAS2 sans lettre plutôt que de la déclarer en « autres »" do
      lines = [Payload::Das2Line.new("F2", "Agence Martin", "", "", "", "", "", "FR", {"mystere" => "90"}, "90")]
      payload = Payload.new("das2", %w[DAS2], identity, "2026-01-01", "2026-12-31", das2: lines)
      error = expect_raises(Teledec::TransportError) { white_label(payload) }
      error.key.should eq("teledec.errors.transport.das2_nature")
      error.params["nature"].should eq("mystere")
    end

    it "refuse une sorte sans formulaire de marque blanche" do
      payload = Payload.new("greffe", %w[greffe], identity, "2026-01-01", "2026-12-31")
      expect_raises(Teledec::TransportError, "teledec.errors.transport.unsupported") { white_label(payload) }
    end
  end

  describe "liasse (API Balance)" do
    it "omet les lignes d'identification vides, nettoie la balance et joint les cases de la 2035 en euros" do
      rows = [Payload::BalanceRow.new("6064", "Fournitures;bureau\nA", "120.00", "0.00", "120.00", "0.00")]
      payload = Payload.new("liasse", %w[2035], identity(legal_form: "", street: ""), "2026-01-01", "2026-12-31",
        balance: rows, boxes: {"2035-A" => {"AA" => "1234.50", "BB" => "0"}})
      text = Formats.liasse(payload, submission("liasse"), credentials(siret: ""), "PARTIDUO", false)
      lines = text.lines
      lines.should contain("#CATEGORIE-FISCALE BNC")
      lines.any?(&.starts_with?("#REEL-NORMAL-OU-SIMPLIFIE")).should be_false
      lines.any?(&.starts_with?("#SIRET")).should be_false
      lines.any?(&.starts_with?("#FORME-JURIDIQUE")).should be_false
      lines.any?(&.starts_with?("#ADRESSE-NUMERO-RUE")).should be_false
      lines.should contain("#AFFICHAGE-BOUTON-ENVOYER NON")
      lines.should contain("6064;Fournitures bureau A;0;0;120.00;0.00;120.00;0.00")
      zones = JSON.parse(lines.last)["zones_formulaires"]
      zones["2035A"]["AA_2035A"].as_i.should eq(1235)
      zones["2035A"]["BB_2035A"].as_i.should eq(0)
    end

    it "classe la liasse d'après ses formulaires (BIC IS/IR, réel normal ou simplifié, SCI)" do
      cases = { %w[2065 2050] => {"BIC-IS", "NORMAL"}, %w[2031 2033] => {"BIC-IR", "SIMPLIFIE"},
               %w[2031 2050] => {"BIC-IR", "NORMAL"}, %w[2072] => {"SCI2072", nil} }
      cases.each do |forms, (category, regime)|
        payload = Payload.new("liasse", forms, identity, "2026-01-01", "2026-12-31")
        lines = Formats.liasse(payload, submission("liasse"), credentials, "PARTIDUO", true).lines
        lines.should contain("#CATEGORIE-FISCALE #{category}")
        regime ? lines.should(contain("#REEL-NORMAL-OU-SIMPLIFIE #{regime}")) : lines.any?(&.starts_with?("#REEL")).should(be_false)
        lines.any?(&.starts_with?("{")).should be_false
      end
    end
  end

  describe "comptes-rendus" do
    it "lit les dates de TELEDEC en heure française (avec ou sans heure), rien pour une date illisible" do
      Formats.parse_time("2027-05-10T10:30:00").should eq(Time.utc(2027, 5, 10, 8, 30))
      Formats.parse_time("2027-05-10 10:30:00").should eq(Time.utc(2027, 5, 10, 8, 30))
      Formats.parse_time("2027-01-10T10:30:00.123+01:00").should eq(Time.utc(2027, 1, 10, 9, 30))
      Formats.parse_time("2027-05-10").should eq(Time.utc(2027, 5, 9, 22, 0))
      Formats.parse_time("").should be_nil
      Formats.parse_time("demain").should be_nil
    end

    it "donne le motif : erreurs de la DGFiP, sinon code et libellé, sinon libellé du statut" do
      errors = JSON.parse(<<-JSON)
        {"status": "ERREUR", "statusLibelle": "Rejeté", "declarationErreurs": [
          {"formulaire": "2033A", "champ": "FL", "code": "E7", "libelle": "Total faux"},
          {"code": 12, "libelle": "Autre"}, "pas un objet", {}]}
        JSON
      Formats.report(errors).reason.should eq("2033A FL : E7 Total faux ; 12 Autre")
      Formats.report(JSON.parse(%({"status": "ERREUR", "erreurCode": 101}))).reason.should eq("101")
      Formats.report(JSON.parse(%({"status": "Rejected", "statusLibelle": "Refusé par la DGFiP"}))).reason
        .should eq("Refusé par la DGFiP")
    end

    it "prend le statut des formulaires quand il tranche, garde un PDF illisible à nil, refuse un corps non objet" do
      report = Formats.report(JSON.parse(%({"declarationId": 7, "status": "Sent", "formulairesStatus": "OK", "pdf": "%%%"})))
      report.state.should eq("acknowledged")
      report.status.should eq("OK")
      report.pdf.should be_nil
      report.declaration_id.should eq("7")
      # Parti à la DGFiP, pas encore accepté : l'étape du rappel (`OK`) ne
      # fait pas foi.
      sent = Formats.report(JSON.parse(%({"formulairesStatus": "Sent", "status": "OK"})))
      sent.status.should eq("Sent")
      sent.state.should eq("pending")
      Formats.report(JSON.parse(%({"formulairesStatus": "", "status": "OK"}))).state.should eq("acknowledged")
      Formats.report(JSON.parse(%({"formulairesStatus": "Rejected", "status": "OK"}))).state.should eq("rejected")
      pending = Formats.report(JSON.parse(%({"status": null, "declarationStatus": "NotCompleted"})))
      pending.status.should eq("NotCompleted")
      pending.state.should eq("pending")
      encoded = Formats.report(JSON.parse(%({"status": "OK", "pdf": "#{Base64.strict_encode("%PDF-1.4")}"})))
      String.new(encoded.pdf || raise "PDF absent").should eq("%PDF-1.4")
      expect_raises(Teledec::TransportError, "teledec.errors.transport.invalid") { Formats.report(JSON.parse("[1]")) }
    end

    it "écarte les rappels de paiement et ceux d'un autre type de déclaration, et reconnaît un autre envoi" do
      payment = Formats.report(JSON.parse(%({"declarationType": "Paiement", "status": "ERREUR", "reference": "r-1"})))
      payment.declaration_type.should eq("Paiement")
      payment.payment?.should be_true
      Formats.concerns?(payment, "vat_ca3").should be_false
      Formats.concerns?(payment, "das2").should be_false
      tva = Formats.report(JSON.parse(%({"declarationType": "TVA", "status": "OK"})))
      Formats.concerns?(tva, "vat_ca12").should be_true
      Formats.concerns?(tva, "liasse").should be_false
      Formats.concerns?(tva, "das2").should be_true
      Formats.concerns?(Formats.report(JSON.parse(%({"status": "OK"}))), "liasse").should be_true
      payment.stale?("r-1").should be_false
      payment.stale?("r-2").should be_true
      payment.stale?("").should be_false
      tva.stale?("r-2").should be_false
    end

    it "sans date, retient le dernier compte-rendu de la liste" do
      first = Formats::Report.new("1", "r", "ERREUR", "a", nil, nil, "")
      last = Formats::Report.new("2", "r", "OK", "", nil, nil, "")
      Formats.latest([first, last]).should eq(last)
      dated = Formats::Report.new("3", "r", "ERREUR", "b", nil, Time.utc(2020, 1, 1), "")
      Formats.latest([first, dated, last]).should eq(dated)
    end

    it "normalise un statut : minuscules, lettres seules" do
      Formats.normalize(" Ready_To-Be Sent ").should eq("readytobesent")
      Formats.state("complete with errors").should eq("rejected")
      Formats.state("").should eq("pending")
    end
  end
end
