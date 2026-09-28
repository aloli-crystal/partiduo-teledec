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
  # * Montant : toutes taxes comprises — la TVA de l'écriture est répartie
  #   au prorata des bases hors taxe.
  # * Seuil : un bénéficiaire n'est déclaré qu'au-delà de `threshold`
  #   (1 200 € par an et par bénéficiaire) ; montants en euros entiers.
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
        taxable = entry.lines.reject { |line| line.vat_role == "tax" }
        found = taxable.compact_map do |line|
          prefix = prefixes.find { |item| line.account_number.starts_with?(item) }
          prefix.try { |item| {line, accounts[item]} }
        end
        next if found.empty?
        base_total = taxable.select { |line| line.vat_role == "base" }.sum(Money::ZERO) { |line| line.debit - line.credit }
        vat_total = entry.lines.select { |line| line.vat_role == "tax" && line.account_number.starts_with?("4456") }
          .sum(Money::ZERO) { |line| line.debit - line.credit }
        party = entry.lines.find { |line| line.card_code && line.account_number.starts_with?("40") }
        found.each do |(line, nature)|
          amount = line.debit - line.credit
          amount += vat_total * amount / base_total unless base_total.zero? || vat_total.zero?
          code = party.try(&.card_code) || line.card_code
          if code.nil?
            orphans << Orphan.new(entry.id, entry.receipt || entry.internal_code, amount)
            next
          end
          by_nature = totals[code] ||= {} of String => BigDecimal
          by_nature[nature] = (by_nature[nature]? || Money::ZERO) + amount
        end
      end
      all = totals.map do |code, amounts|
        Beneficiary.new(code, amounts.transform_values { |value| Money.euros(value) }.reject { |_, value| value.zero? })
      end.sort_by!(&.card_code)
      declared, below = all.partition { |item| item.total >= threshold && item.total > 0 }
      Result.new(declared, below, orphans)
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
