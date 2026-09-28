# SPDX-License-Identifier: AGPL-3.0-or-later

module Teledec
  # DAS2 d'une année civile (ADR-007 D4) : honoraires, commissions,
  # courtages, droits d'auteur… versés à des tiers, calculés depuis les
  # écritures et les fiches fournisseurs (DECISIONS D-TDC-007).
  #
  # * Lignes retenues : lignes des comptes paramétrés (préfixe → nature,
  #   `Config::DAS2_ACCOUNTS` par défaut), hors lignes de TVA, de l'année
  #   civile, extournes comprises (elles annulent l'écriture d'origine).
  # * Bénéficiaire : la fiche de la ligne de tiers (compte `40…`) de
  #   l'écriture, à défaut la fiche portée par la ligne de charge.
  # * Écritures de clôture et de réouverture (`closing:`, `opening:`)
  #   écartées : elles soldent les comptes sans fiche et ne sont pas des
  #   versements (comme `Balance.compute`, qui neutralise la clôture).
  # * Montant : toutes taxes comprises — la TVA déductible (4456) de
  #   l'écriture est répartie au prorata des bases hors taxe, sur les seules
  #   lignes de base (`vat_role == "base"`) : une ligne exonérée n'en reçoit
  #   pas. TVA autoliquidée (écriture qui porte aussi une ligne 4452) : le
  #   prestataire ne l'a pas perçue, elle n'est pas ajoutée.
  # * Seuil : un bénéficiaire n'est déclaré que si ses sommes de l'année
  #   *dépassent* `threshold` (1 200 € par an et par bénéficiaire, CGI
  #   art. 240 : 1 200 € tout rond n'est pas déclaré) ; montants déclarés
  #   en euros entiers.
  module Das2
    alias Acc = Partiduo::Api::Accounting

    PAGE = 500

    record Beneficiary, card_code : String, amounts : Hash(String, BigDecimal) do
      def total : BigDecimal
        amounts.values.sum(Money::ZERO)
      end
    end

    # Écriture dont une ligne de charge n'a pas de fiche de tiers.
    record Orphan, entry_id : Int64, receipt : String, amount : BigDecimal

    record Result, beneficiaries : Array(Beneficiary), below : Array(Beneficiary), orphans : Array(Orphan)

    def self.system : Partiduo::Api::Actor
      Partiduo::Api::Actor.system
    end

    def self.compute(year : Int32, accounts : Hash(String, String), threshold : BigDecimal) : Result
      prefixes = accounts.keys.sort_by! { |prefix| -prefix.size }
      totals = {} of String => Hash(String, BigDecimal)
      orphans = [] of Orphan
      entries(year, accounts.keys).each do |entry|
        next if year_end?(entry)
        taxable = entry.lines.reject { |line| line.vat_role == "tax" }
        found = taxable.compact_map do |line|
          prefix = prefixes.find { |item| line.account_number.starts_with?(item) }
          prefix.try { |item| {line, accounts[item]} }
        end
        next if found.empty?
        vat = vat_by_rate(entry)
        party = entry.lines.find { |line| line.card_code && line.account_number.starts_with?("40") }
        found.each do |(line, nature)|
          amount = line.debit - line.credit
          if line.vat_role == "base" && (share = vat[line.vat_rate_code]?)
            base_total, vat_total = share
            amount += vat_total * amount / base_total unless base_total.zero? || vat_total.zero?
          end
          code = party.try(&.card_code) || line.card_code
          if code.nil?
            orphans << Orphan.new(entry.id, entry.receipt || entry.internal_code, amount)
            next
          end
          by_nature = totals[code] ||= {} of String => BigDecimal
          by_nature[nature] = (by_nature[nature]? || Money::ZERO) + amount
        end
      end
      # Seuil : sommes qui *dépassent* 1 200 € (CGI, art. 240), appréciées
      # sur le total exact de l'année, toutes natures confondues, avant
      # l'arrondi à l'euro des montants déclarés.
      declared = [] of Beneficiary
      below = [] of Beneficiary
      totals.keys.sort!.each do |code|
        amounts = totals[code]
        exact = amounts.values.sum(Money::ZERO)
        item = Beneficiary.new(code, amounts.transform_values { |value| Money.euros(value) }.reject { |_, value| value.zero? })
        (exact > threshold && exact > 0 ? declared : below) << item
      end
      Result.new(declared, below, orphans)
    end

    # TVA déductible répartissable, par code de TVA : {bases hors taxe, TVA
    # 4456}. Une ligne de base ne reçoit que la TVA de son propre taux (une
    # ligne exonérée, sans TVA, n'en reçoit donc pas). Autoliquidation
    # écartée : un taux dont une ligne de TVA n'est pas sur 4456 (TVA due,
    # 4452 ou 4457, passée en même temps que la TVA déductible), et, pour
    # une écriture saisie sans code de TVA, toute ligne 4452.
    def self.vat_by_rate(entry : Acc::EntryView) : Hash(String?, {BigDecimal, BigDecimal})
      tax = entry.lines.select { |line| line.vat_role == "tax" }
      reverse_charge = tax.reject(&.account_number.starts_with?("4456")).map(&.vat_rate_code).to_set
      reverse_charge << nil if entry.lines.any?(&.account_number.starts_with?("4452"))
      shares = {} of String? => {BigDecimal, BigDecimal}
      entry.lines.each do |line| # ameba:disable Performance/ExcessiveAllocations
        next if reverse_charge.includes?(line.vat_rate_code)
        base, vat = shares[line.vat_rate_code]? || {Money::ZERO, Money::ZERO}
        signed = line.debit - line.credit
        if line.vat_role == "base"
          shares[line.vat_rate_code] = {base + signed, vat}
        elsif line.vat_role == "tax"
          shares[line.vat_rate_code] = {base, vat + signed}
        end
      end
      shares
    end

    # Écriture de clôture ou de réouverture d'un exercice (ADR-006 : la
    # Comptabilité les marque par leur `source`).
    YEAR_END_SOURCES = {"closing:", "opening:", "reopening:"}

    def self.year_end?(entry : Acc::EntryView) : Bool
      YEAR_END_SOURCES.any? { |prefix| entry.source.starts_with?(prefix) }
    end

    # Écritures de l'année qui touchent un compte de la DAS2, sans doublon.
    private def self.entries(year : Int32, prefixes : Array(String)) : Array(Acc::EntryView)
      seen = Set(Int64).new
      found = [] of Acc::EntryView
      prefixes.each do |prefix|
        offset = 0
        loop do
          query = Acc::EntryQuery.new(date_from: Time.utc(year, 1, 1), date_to: Time.utc(year, 12, 31), account: prefix,
            account_prefix: true, include_cancelled: true, offset: offset, limit: PAGE)
          page = Acc.entries(system, query)
          page.each { |entry| found << entry if seen.add?(entry.id) }
          break if page.size < PAGE
          offset += PAGE
        end
      end
      found
    end
  end
end
