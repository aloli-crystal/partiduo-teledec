# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private def d(text : String) : Time
  Time.parse_utc(text, "%Y-%m-%d")
end

describe Teledec::Calendar do
  it "place la liasse d'un exercice civil au deuxième jour ouvré suivant le 1er mai, plus quinze jours" do
    # 1er mai 2027 : samedi → lundi 3, mardi 4 ; + 15 jours.
    Teledec::Calendar.second_business_day_after_may_first(2027).should eq(d("2027-05-04"))
    Teledec::Calendar.liasse(d("2026-12-31")).should eq(d("2027-05-19"))
    # Exercice décalé : trois mois après la clôture, plus quinze jours.
    Teledec::Calendar.liasse(d("2026-06-30")).should eq(d("2026-10-15"))
  end

  it "place le solde d'IS au 15 mai ou au 15 du quatrième mois, les acomptes aux 15 mars, juin, septembre, décembre" do
    Teledec::Calendar.corporate_tax_balance(d("2026-12-31")).should eq(d("2027-05-15"))
    Teledec::Calendar.corporate_tax_balance(d("2026-06-30")).should eq(d("2026-10-15"))
    Teledec::Calendar.corporate_tax_advances(d("2026-01-01"), d("2026-12-31"))
      .should eq([d("2026-03-15"), d("2026-06-15"), d("2026-09-15"), d("2026-12-15")])
    Teledec::Calendar.corporate_tax_advances(d("2026-07-01"), d("2027-06-30"))
      .should eq([d("2026-09-15"), d("2026-12-15"), d("2027-03-15"), d("2027-06-15")])
  end

  it "découpe l'exercice en périodes de TVA et fixe les échéances de TVA, de la DAS2 et du greffe" do
    Teledec::Calendar.vat_periods(d("2026-01-01"), d("2026-12-31"), 3).size.should eq(4)
    Teledec::Calendar.vat_periods(d("2026-01-01"), d("2026-12-31"), 1).last.should eq({d("2026-12-01"), d("2026-12-31")})
    Teledec::Calendar.vat_monthly(d("2026-12-31")).should eq(d("2027-01-19"))
    Teledec::Calendar.vat_annual(d("2026-12-31")).should eq(d("2027-05-04"))
    Teledec::Calendar.das2(2026).should eq(d("2027-05-04"))
    Teledec::Calendar.greffe(d("2026-12-31")).should eq(d("2027-07-31"))
  end
end
