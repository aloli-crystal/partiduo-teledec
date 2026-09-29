# SPDX-License-Identifier: AGPL-3.0-or-later

module Teledec
  # Cohérence d'une déclaration de TVA arrondie à l'euro (DECISIONS
  # D-TDC-026) : chaque case de détail est arrondie à l'euro, puis les
  # lignes de total sont recalculées à partir des cases arrondies, comme la
  # DGFiP les contrôle (16 = somme des taxes brutes et de la ligne 15,
  # 23 = somme des lignes 19 à 22, 25 et 28 par différence, 27 = 25 − 26,
  # 32 = 28 + 29 ; CA12 : solde `sp` ou excédent `ex` après les acomptes
  # `ac`). Mêmes formules que la déclaration de TVA de la Comptabilité
  # (module `vat` du cœur, cases CA3 et CA12), reprises ici sur les montants
  # arrondis : arrondir chaque total séparément donnerait 100 + 100 = 201.
  module VatTotals
    RATE_LINES = %w[08 09 9B 10 11 13 14]
    TOTALS     = {
      "vat_ca3"  => %w[16 23 25 27 28 32],
      "vat_ca12" => %w[16 23 25 28 sp ex],
    }

    # Cases arrondies à l'euro (texte), totaux recalculés ; les cases
    # nulles sont retirées. `kind` : `vat_ca3` ou `vat_ca12` (sinon les
    # cases sont seulement arrondies).
    def self.coherent(kind : String, boxes : Hash(String, String)) : Hash(String, String)
      amounts = boxes.transform_values { |text| Money.euros(Money.parse(text)) }
      annex!(amounts)
      if totals = TOTALS[kind]?
        totals.each { |code| amounts.delete(code) }
        compute(kind, amounts)
      end
      amounts.reject { |_, value| value.zero? }.transform_values { |value| Money.euros_text(value) }
    end

    # Ligne de l'annexe (taux particuliers, `14.<taux>.base|tax`).
    ANNEX = /\A14\.[A-Z0-9_]+\.(base|tax)\z/

    # Ligne 14 reportée des lignes de l'annexe arrondies, quand il y en a
    # (comme la Comptabilité, D-R5-006) : la ligne 14 égale la somme de ce
    # qui part taux par taux.
    private def self.annex!(amounts : Hash(String, BigDecimal)) : Nil
      lines = amounts.select { |code, _| code.matches?(ANNEX) }
      return if lines.empty?
      amounts["14.base"] = lines.sum(Money::ZERO) { |code, value| code.ends_with?(".base") ? value : Money::ZERO }
      amounts["14.tax"] = lines.sum(Money::ZERO) { |code, value| code.ends_with?(".tax") ? value : Money::ZERO }
      nil
    end

    private def self.compute(kind : String, amounts : Hash(String, BigDecimal)) : Nil
      get = ->(code : String) { amounts[code]? || Money::ZERO }
      gross = RATE_LINES.sum(Money::ZERO) { |line| get.call("#{line}.tax") } + get.call("15")
      deductible = %w[19 20 21 22].sum(Money::ZERO) { |code| get.call(code) }
      credit = positive(deductible - gross)
      net = positive(gross - deductible)
      amounts["16"] = gross
      amounts["23"] = deductible
      amounts["25"] = credit
      amounts["28"] = net
      due = net + get.call("29")
      if kind == "vat_ca3"
        amounts["27"] = positive(credit - get.call("26"))
        amounts["32"] = due
      else
        paid = get.call("ac")
        amounts["sp"] = positive(due - paid)
        amounts["ex"] = positive(paid - due)
      end
      nil
    end

    private def self.positive(value : BigDecimal) : BigDecimal
      value > 0 ? value : Money::ZERO
    end
  end
end
