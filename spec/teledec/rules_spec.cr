# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Calendar = Teledec::Calendar
private alias Money = Teledec::Money
private alias Secrets = Teledec::Secrets

private def d(text : String) : Time
  Time.parse_utc(text, "%Y-%m-%d")
end

private def dec(text : String) : BigDecimal
  BigDecimal.new(text)
end

private def with_env(name : String, value : String?, &)
  previous = ENV[name]?
  value ? (ENV[name] = value) : ENV.delete(name)
  yield
ensure
  previous ? (ENV[name] = previous) : ENV.delete(name)
end

private def identity : Teledec::Payload::Identity
  Teledec::Payload::Identity.new("Atelier Brunet SARL", "SARL", "732829320", "FR44732829320", "Lyon B 732 829 320",
    "10000.00", "3 rue des Lilas", "69003", "Lyon", "FR", "compta@example.com")
end

describe "Arrondis des montants transmis (Teledec::Money)" do
  it "écrit les montants au centime, au point, sans flottant, en arrondissant la demie loin de zéro" do
    Money.cents(dec("1234.5")).should eq("1234.50")
    Money.cents(dec("0.05")).should eq("0.05")
    Money.cents(dec("0")).should eq("0.00")
    Money.cents(dec("-12.345")).should eq("-12.35")
    Money.cents(dec("0.005")).should eq("0.01")
    Money.cents(dec("-0.004")).should eq("0.00")
    Money.cents(dec("123456789012.99")).should eq("123456789012.99")
  end

  it "arrondit à l'euro le plus proche, 0,50 à l'euro supérieur (arrondi fiscal)" do
    Money.euros_text(dec("2.5")).should eq("3")
    Money.euros_text(dec("2.49")).should eq("2")
    Money.euros_text(dec("-2.5")).should eq("-3")
    Money.euros_text(dec("1200.4")).should eq("1200")
    Money.euros(dec("0.5")).should eq(dec("1"))
  end

  it "lit un montant illisible comme zéro" do
    Money.parse("12.30").should eq(dec("12.3"))
    Money.parse("douze").should eq(Money::ZERO)
    Money.parse("").should eq(Money::ZERO)
  end
end

describe "Identifiants chiffrés (Teledec::Secrets, D-TDC-005)" do
  it "chiffre avec un vecteur aléatoire et déchiffre" do
    Secrets.encrypt("").should eq("")
    Secrets.decrypt("").should eq("")
    one = Secrets.encrypt("cle-de-test-0123456789")
    two = Secrets.encrypt("cle-de-test-0123456789")
    one.should start_with("v1:")
    one.should_not eq(two)
    one.should_not contain("cle-de-test")
    Secrets.decrypt(one).should eq("cle-de-test-0123456789")
    Secrets.decrypt(two).should eq("cle-de-test-0123456789")
    Secrets.decrypt_json(Secrets.encrypt_json({"login" => "cabinet"})).should eq({"login" => "cabinet"})
    Secrets.encrypt_json({} of String => String).should eq("")
  end

  it "refuse un secret altéré, tronqué, en clair ou chiffré avec une autre clé" do
    sealed = Secrets.encrypt("cle-de-test-0123456789")
    body = Base64.decode(sealed.lchop("v1:"))
    body[20] ^= 1_u8
    expect_raises(Secrets::Error, /altéré/) { Secrets.decrypt("v1:" + Base64.strict_encode(body)) }
    expect_raises(Secrets::Error, /tronqué/) { Secrets.decrypt("v1:" + Base64.strict_encode(body[0, 40])) }
    expect_raises(Secrets::Error, /format/) { Secrets.decrypt("cle-en-clair") }
    with_env("PARTIDUO_TELEDEC_KEY", "ab" * 32) do
      other = Secrets.encrypt("cle")
      Secrets.decrypt(other).should eq("cle")
      expect_raises(Secrets::Error) { Secrets.decrypt(sealed) }
      with_env("PARTIDUO_TELEDEC_KEY", "cd" * 32) do
        expect_raises(Secrets::Error) { Secrets.decrypt(other) }
      end
    end
    # Clé mal formée : ignorée, la clé dérivée de l'instance s'applique.
    with_env("PARTIDUO_TELEDEC_KEY", "trop-courte") do
      Secrets.decrypt(sealed).should eq("cle-de-test-0123456789")
    end
  end
end

describe "Document transmis (Teledec::Payload, D-TDC-008)" do
  it "garde son empreinte après relecture et la change à la moindre modification" do
    rows = [Teledec::Payload::BalanceRow.new("706", "Ventes", "0.00", "1000.00", "0.00", "1000.00")]
    payload = Teledec::Payload.new("liasse", %w[2065 2033], identity, "2026-01-01", "2026-12-31", 0, rows,
      nil, nil, nil, {"closing_neutralised" => "1"})
    payload.fingerprint.size.should eq(64)
    payload.fingerprint.should match(/\A[0-9a-f]{64}\z/)
    reread = Teledec::Payload.from_json(payload.to_json)
    reread.fingerprint.should eq(payload.fingerprint)
    reread.schema.should eq("partiduo-teledec/1")
    changed = Teledec::Payload.new("liasse", %w[2065 2033], identity, "2026-01-01", "2026-12-31", 0,
      [Teledec::Payload::BalanceRow.new("706", "Ventes", "0.00", "1000.01", "0.00", "1000.01")], nil, nil, nil,
      {"closing_neutralised" => "1"})
    changed.fingerprint.should_not eq(payload.fingerprint)
    # Montants en texte, jamais en nombre flottant.
    JSON.parse(payload.to_json)["balance"][0]["credit"].as_s.should eq("1000.00")
  end
end

describe "Échéances : cas limites du calendrier (D-TDC-006)" do
  it "compte deux jours ouvrés après le 1er mai, week-end exclu" do
    Calendar.second_business_day_after_may_first(2025).should eq(d("2025-05-05")) # jeudi → ven. 2, lun. 5
    Calendar.second_business_day_after_may_first(2026).should eq(d("2026-05-05")) # vendredi → lun. 4, mar. 5
    Calendar.second_business_day_after_may_first(2028).should eq(d("2028-05-03")) # lundi → mar. 2, mer. 3
    Calendar.second_business_day_after_may_first(2027).should eq(d("2027-05-04")) # samedi → lun. 3, mar. 4
    Calendar.das2(2027).should eq(d("2028-05-03"))
  end

  it "ajoute des mois en bornant à la fin du mois, années bissextiles comprises" do
    Calendar.add_months(d("2026-01-31"), 1).should eq(d("2026-02-28"))
    Calendar.add_months(d("2028-01-31"), 1).should eq(d("2028-02-29"))
    Calendar.add_months(d("2026-11-30"), 3).should eq(d("2027-02-28"))
    Calendar.add_months(d("2026-03-15"), -3).should eq(d("2025-12-15"))
  end

  it "place les échéances d'un exercice décalé" do
    Calendar.liasse(d("2026-09-30")).should eq(d("2027-01-14")) # 30 décembre + 15 jours
    Calendar.liasse(d("2027-02-28")).should eq(d("2027-06-12")) # 28 mai + 15 jours
    Calendar.corporate_tax_balance(d("2026-09-30")).should eq(d("2027-01-15"))
    Calendar.corporate_tax_balance(d("2026-11-30")).should eq(d("2027-03-15"))
    Calendar.vat_annual(d("2026-06-30")).should eq(d("2026-09-30"))
    Calendar.greffe(d("2026-06-30")).should eq(d("2027-01-31"))
    Calendar.greffe(d("2026-07-31")).should eq(d("2027-02-28"))
  end

  it "ne retient que les acomptes compris dans l'exercice, quatre au plus" do
    Calendar.corporate_tax_advances(d("2026-05-01"), d("2026-12-31"))
      .should eq([d("2026-06-15"), d("2026-09-15"), d("2026-12-15")])
    Calendar.corporate_tax_advances(d("2026-01-01"), d("2027-06-30")).size.should eq(4)
    Calendar.corporate_tax_advances(d("2026-03-16"), d("2026-06-14")).should be_empty
    # Bornes incluses.
    Calendar.corporate_tax_advances(d("2026-03-15"), d("2026-03-15")).should eq([d("2026-03-15")])
  end

  it "découpe un exercice décalé en mois ou en trimestres civils, et fixe la CA3 au 19 du mois suivant" do
    months = Calendar.vat_periods(d("2026-07-01"), d("2027-06-30"), 1)
    months.size.should eq(12)
    months.first.should eq({d("2026-07-01"), d("2026-07-31")})
    months.last.should eq({d("2027-06-01"), d("2027-06-30")})
    quarters = Calendar.vat_periods(d("2026-02-01"), d("2027-01-31"), 3)
    quarters.size.should eq(5)
    quarters.first.should eq({d("2026-01-01"), d("2026-03-31")})
    quarters.last.should eq({d("2027-01-01"), d("2027-03-31")})
    Calendar.vat_monthly(d("2026-11-30")).should eq(d("2026-12-19"))
    Calendar.vat_monthly(d("2026-03-31")).should eq(d("2026-04-19"))
  end
end

describe "Balance de repli (CSV, D-TDC-004)" do
  it "neutralise les formules et les séparateurs dans les intitulés, et totalise les soldes" do
    zero = Money::ZERO
    rows = [
      Teledec::Balance::Row.new("401", "=HYPERLINK(\"x\");piège", zero, dec("100"), dec("250.5")),
      Teledec::Balance::Row.new("512", "-Banque\r\nbis", zero, dec("250.5"), dec("100")),
    ]
    result = Teledec::Balance::Result.new(rows, false)
    result.total_debit.should eq(dec("150.5"))
    result.total_credit.should eq(dec("150.5"))
    result.balanced?.should be_true
    result.signed("4").should eq(dec("-150.5"))
    lines = Teledec::Balance.csv(result).split("\r\n")
    lines[1].should eq(%(401;'=HYPERLINK("x") piège;100,00;250,50;0,00;150,50))
    lines[2].should eq("512;'-Banque  bis;250,50;100,00;150,50;0,00")
    lines.size.should eq(4) # en-tête, deux lignes, fin de fichier
    lines.last.should eq("")
  end

  it "signale un solde déséquilibré" do
    zero = Money::ZERO
    result = Teledec::Balance::Result.new([Teledec::Balance::Row.new("706", "Ventes", zero, zero, dec("10"))], false)
    result.balanced?.should be_false
    # Un compte soldé mais mouvementé reste dans la balance ; seul un compte
    # sans mouvement ni solde en sort.
    Teledec::Balance::Row.new("706", "Ventes", zero, dec("5"), dec("5")).zero?.should be_false
    Teledec::Balance::Row.new("706", "Ventes", zero, zero, zero).zero?.should be_true
  end
end
