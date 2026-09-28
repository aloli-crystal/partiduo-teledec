# SPDX-License-Identifier: AGPL-3.0-or-later

module Teledec
  # Valeurs fermées de l'extension (vérifiées aussi en base par la
  # migration 0001).
  module Config
    # Sortes de déclarations (ADR-007 D4).
    #
    # * `liasse` : liasse fiscale de l'exercice, formulaires selon le régime
    #   d'imposition (`FORMS`) ;
    # * `vat_ca3`, `vat_ca12` : déclarations de TVA préparées et closes par
    #   la Comptabilité (lot 4) ;
    # * `das2` : honoraires, commissions et droits versés à des tiers, par
    #   année civile ;
    # * `is_2571` : relevé d'acompte d'impôt sur les sociétés (quatre par
    #   exercice) ; `is_2572` : relevé de solde ;
    # * `greffe` : dépôt des comptes annuels au greffe (option).
    KINDS = %w[liasse vat_ca3 vat_ca12 das2 is_2571 is_2572 greffe]

    # Régimes d'imposition du dossier et formulaires de la liasse. La
    # formule API Balance envoie la balance et l'identité : TELEDEC remplit
    # les cases (ADR-007 D4), Partiduo ne les calcule pas.
    FORMS = {
      "is_rsi"  => %w[2065 2033],
      "is_rn"   => %w[2065 2050],
      "bic_rsi" => %w[2031 2033],
      "bic_rn"  => %w[2031 2050],
      "bnc"     => %w[2035],
      "sci"     => %w[2072],
    }
    TAX_SYSTEMS = FORMS.keys

    # Régimes d'imposition soumis à l'impôt sur les sociétés (relevés 2571
    # et 2572).
    CORPORATE_TAX_SYSTEMS = %w[is_rsi is_rn]

    # Régime de TVA : CA3 mensuelle ou trimestrielle, CA12 annuelle, aucune
    # déclaration (franchise en base).
    VAT_SYSTEMS = %w[ca3_monthly ca3_quarterly ca12 none]

    # Statuts d'un dépôt (ADR-007 D4) : préparé, transmis, accusé de
    # réception, rejeté (avec motif).
    STATUSES = %w[prepared transmitted acknowledged rejected]

    # Environnements de l'API partenaire.
    ENVIRONMENTS = %w[sandbox production]

    # Natures de la DAS2 et comptes proposés par défaut (préfixes du plan
    # comptable général) ; paramétrables (`Api.update_settings`).
    DAS2_NATURES   = %w[fees commissions brokerage rebates attendance copyright inventor other]
    DAS2_ACCOUNTS  = {"6226" => "fees", "6221" => "commissions", "6222" => "commissions", "6516" => "copyright"}
    DAS2_THRESHOLD = BigDecimal.new(1200)

    # Formulaires d'une sorte de déclaration.
    def self.forms(kind : String, tax_system : String) : Array(String)
      case kind
      when "liasse"   then FORMS[tax_system]? || [] of String
      when "vat_ca3"  then ["3310-CA3"]
      when "vat_ca12" then ["3517-S-CA12"]
      when "das2"     then ["DAS2"]
      when "is_2571"  then ["2571"]
      when "is_2572"  then ["2572"]
      else                 ["greffe"]
      end
    end
  end
end
