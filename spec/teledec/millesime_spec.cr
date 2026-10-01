# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Millesime = Teledec::Remote::Millesime

describe "Millésimes des formulaires de TELEDEC (D-TDC6-001)" do
  it "range les millésimes : l'année vaut son premier palier" do
    Millesime.rank(2025).should eq(202501)
    Millesime.rank(202502).should eq(202502)
    Millesime.rank(2026).should eq(Millesime.rank(202601))
  end

  it "liasse : année du lendemain de la clôture (réponses de TELEDEC du 1er octobre 2026)" do
    Millesime.campaign("liasse", "2024-12-31").should eq(2025) # exemple du guide de l'API Liasse
    Millesime.campaign("liasse", "2025-12-31").should eq(2026) # exemple de TELEDEC
    Millesime.campaign("liasse", "2025-06-30").should eq(2025) # lendemain 01/07/2025
    Millesime.campaign("liasse", "2026-06-30").should eq(2026)
    Millesime.campaign("liasse", "2025-09-30").should eq(2025)
    Millesime.campaign("liasse", "2025-12-30").should eq(2025) # lendemain 31/12/2025
    Millesime.campaign("liasse", "2024-02-29").should eq(2024) # année bissextile
    Millesime.target("liasse", "2025-12-31").should eq(202601)
  end

  it "DAS2 : année du lendemain de la clôture (sommes de 2025, campagne 2026)" do
    Millesime.campaign("das2", "2025-12-31").should eq(2026)
    Millesime.target("das2", "2025-12-31").should eq(202601)
  end

  it "TVA (palier interne, jamais transmis) : année de la période, palier pour une période close à partir du 1er juin 2025 ou 2026" do
    Millesime.target("vat_ca3", "2025-02-28").should eq(202501) # 3310A de février 2025 → 2025
    Millesime.pick([2024, 2025, 202502, 202601], Millesime.target("vat_ca3", "2025-02-28")).should eq(2025)
    Millesime.target("vat_ca3", "2026-01-31").should eq(202601) # 3310TIC de janvier 2026 → 202601
    Millesime.campaign("vat_ca3", "2025-05-31").should eq(2025)
    Millesime.target("vat_ca3", "2025-05-31").should eq(202501)
    Millesime.target("vat_ca3", "2025-06-30").should eq(202502) # juin 2025, deuxième trimestre 2025
    Millesime.target("vat_ca12", "2025-12-31").should eq(202502)
    Millesime.target("vat_ca3", "2026-01-31").should eq(202601)
    Millesime.target("vat_ca3", "2026-07-31").should eq(202602)
    Millesime.target("vat_ca12", "2027-12-31").should eq(202701)
    Millesime.campaign("vat_ca12", "2025-12-31", "2026-05-05").should eq(2025)
  end

  it "relevés d'IS : année de l'échéance, la précédente avant mars (mise en production du millésime)" do
    Millesime.campaign("is_2572", "2025-12-31", "2026-05-15").should eq(2026)
    Millesime.campaign("is_2571", "2026-12-31", "2026-03-15").should eq(2026)
    Millesime.campaign("is_2572", "2025-10-31", "2026-02-15").should eq(2025)
    Millesime.campaign("is_2571", "2026-12-31").should eq(2026) # sans échéance : fin d'exercice
  end

  it "retient le schéma publié le plus récent qui ne dépasse pas le millésime visé" do
    Millesime.pick([2025], 202601).should eq(2025)                         # 2571 : publié en 2025 seulement
    Millesime.pick([2024, 2025, 202502, 202601], 202602).should eq(202601) # CA12 de juillet 2026
    Millesime.pick([2024, 2025, 202502, 202601], 202502).should eq(202502)
    Millesime.pick([2024, 2025, 202502, 202601], 202501).should eq(2025)
    Millesime.pick([2024, 2025, 202601], 202601).should eq(202601)
    Millesime.pick([2026], 202501).should be_nil # DAS2 de 2024 : aucun schéma
    Millesime.pick([] of Int32, 202601).should be_nil
  end
end
