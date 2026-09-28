# SPDX-License-Identifier: AGPL-3.0-or-later

module Teledec
  # Balance d'un exercice telle que TELEDEC l'attend (formule API Balance) :
  # tous les journaux (une liasse n'est jamais partielle, comme une
  # déclaration de TVA, D-TVA-011), à-nouveaux compris, *avant* l'écriture de
  # clôture de l'exercice (sans quoi les classes 6 et 7 seraient soldées) —
  # DECISIONS D-TDC-003. Lue par `Partiduo::Api::Accounting` avec l'acteur
  # système, après le contrôle des droits de l'acteur par `Teledec::Api`.
  module Balance
    alias Acc = Partiduo::Api::Accounting

    # Ligne calculée (montants exacts, avant mise en forme).
    class Row
      getter number : String
      getter label : String
      property debit : BigDecimal
      property credit : BigDecimal
      getter opening : BigDecimal

      def initialize(@number, @label, @opening, @debit, @credit)
      end

      # Solde final signé (débit − crédit).
      def closing : BigDecimal
        opening + debit - credit
      end

      def zero? : Bool
        debit.zero? && credit.zero? && closing.zero?
      end

      def to_payload : Payload::BalanceRow
        signed = closing
        zero = Money::ZERO
        # Les à-nouveaux sont des écritures de l'exercice (D-ED-001) : la
        # balance part du premier jour, l'ouverture est donc nulle.
        Payload::BalanceRow.new(number, label, Money.cents(debit), Money.cents(credit),
          Money.cents(signed > 0 ? signed : zero), Money.cents(signed < 0 ? -signed : zero))
      end
    end

    record Result, rows : Array(Row), closing_neutralised : Bool do
      def total_debit : BigDecimal
        rows.sum(Money::ZERO) { |row| row.closing > 0 ? row.closing : Money::ZERO }
      end

      def total_credit : BigDecimal
        rows.sum(Money::ZERO) { |row| row.closing < 0 ? -row.closing : Money::ZERO }
      end

      def balanced? : Bool
        total_debit == total_credit
      end

      # Solde signé des comptes commençant par `prefix`.
      def signed(prefix : String) : BigDecimal
        rows.select(&.number.starts_with?(prefix)).sum(Money::ZERO, &.closing)
      end
    end

    def self.system : Partiduo::Api::Actor
      Partiduo::Api::Actor.system
    end

    def self.compute(fiscal_year : Partiduo::Api::Core::FiscalYearView) : Result
      starts_on = fiscal_year.starts_on || raise ArgumentError.new("exercice sans période")
      ends_on = fiscal_year.ends_on || starts_on
      view = Acc.trial_balance(system, Acc::TrialBalanceQuery.new(date_from: starts_on, date_to: ends_on))
      rows = view.rows.map do |row|
        Row.new(row.number, row.label, row.opening.signed, row.debit, row.credit)
      end
      by_number = rows.index_by(&.number)
      closing = Acc.entries(system, Acc::EntryQuery.new(source: "closing:#{fiscal_year.id}", include_cancelled: false, limit: 5))
      closing.each do |entry|
        entry.lines.each do |line| # ameba:disable Performance/ExcessiveAllocations
          row = by_number[line.account_number]? || next
          row.debit -= line.debit
          row.credit -= line.credit
        end
      end
      Result.new(rows.reject(&.zero?).sort_by!(&.number), !closing.empty?)
    end

    # Exercice précédent (celui qui s'achève la veille du premier jour).
    def self.previous(fiscal_year : Partiduo::Api::Core::FiscalYearView) : Partiduo::Api::Core::FiscalYearView?
      starts_on = fiscal_year.starts_on || return
      Partiduo::Api::Core.fiscal_years(system).find { |year| year.ends_on == starts_on - 1.day }
    end

    # En-tête du fichier d'import TELEDEC : format d'échange figé, en
    # français, NON TRADUIT (exception documentée à la règle « aucune chaîne
    # en dur », DECISIONS D-TDC-004).
    CSV_HEADER = "Compte;Intitulé;Débit;Crédit;Solde débiteur;Solde créditeur"

    # Fichier de repli (ADR-007 D5) : balance au format d'import courant
    # (« Compte ; Intitulé ; Débit ; Crédit ; Solde débiteur ; Solde
    # créditeur »), séparateur `;`, virgule décimale, UTF-8 avec marque
    # d'ordre, fin de ligne CRLF — DECISIONS D-TDC-004.
    def self.csv(result : Result) : String
      String.build do |io|
        io << '﻿'
        io << CSV_HEADER << "\r\n"
        result.rows.each do |row|
          line = row.to_payload
          amounts = [line.debit, line.credit, line.balance_debit, line.balance_credit].map(&.tr(".", ","))
          io << ([line.account, csv_text(line.label)] + amounts).join(';') << "\r\n"
        end
      end
    end

    private def self.csv_text(text : String) : String
      clean = text.gsub(/[;\r\n]/, " ").strip
      clean.starts_with?(/[=+\-@]/) ? "'#{clean}" : clean
    end
  end
end
