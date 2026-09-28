# SPDX-License-Identifier: AGPL-3.0-or-later

module Teledec
  # Échéances des déclarations (dates à minuit UTC, comme le cœur). Règles
  # générales du calendrier fiscal des entreprises, sans les reports
  # exceptionnels annoncés chaque année par la DGFiP (DECISIONS D-TDC-006) :
  #
  # * liasse (IS, BIC, BNC, SCI) : exercice clos le 31 décembre → deuxième
  #   jour ouvré suivant le 1ᵉʳ mai, plus quinze jours de délai pour les
  #   télédéclarants ; autre clôture → trois mois après, plus quinze jours ;
  # * relevé de solde d'IS (2572) : clôture au 31 décembre → 15 mai ; sinon
  #   le 15 du quatrième mois suivant la clôture ;
  # * acomptes d'IS (2571) : 15 mars, 15 juin, 15 septembre, 15 décembre
  #   compris dans l'exercice (les quatre premiers) ;
  # * CA3 : le 19 du mois suivant la période ; CA12 : clôture au 31 décembre
  #   → deuxième jour ouvré suivant le 1ᵉʳ mai, sinon trois mois après ;
  # * DAS2 (année civile) : deuxième jour ouvré suivant le 1ᵉʳ mai de
  #   l'année suivante ;
  # * greffe : le dernier jour du septième mois suivant la clôture
  #   (approbation dans les six mois, dépôt dans le mois qui suit).
  module Calendar
    VAT_DAY = 19

    def self.date(year : Int32, month : Int32, day : Int32) : Time
      Time.utc(year, month, day)
    end

    def self.end_of_month(year : Int32, month : Int32) : Time
      date(year, month, Time.days_in_month(year, month))
    end

    # Même jour `months` mois plus tard, borné à la fin du mois.
    def self.add_months(day : Time, months : Int32) : Time
      total = day.year * 12 + (day.month - 1) + months
      year, month = total // 12, total % 12 + 1
      date(year, month, Math.min(day.day, Time.days_in_month(year, month)))
    end

    def self.business_day?(day : Time) : Bool
      !day.saturday? && !day.sunday?
    end

    # Deuxième jour ouvré suivant le 1ᵉʳ mai (samedis et dimanches exclus ;
    # aucun autre jour férié ne tombe avant le 5 mai).
    def self.second_business_day_after_may_first(year : Int32) : Time
      day = date(year, 5, 1)
      count = 0
      while count < 2
        day += 1.day
        count += 1 if business_day?(day)
      end
      day
    end

    def self.december_close?(ends_on : Time) : Bool
      ends_on.month == 12 && ends_on.day == 31
    end

    def self.liasse(ends_on : Time) : Time
      base = december_close?(ends_on) ? second_business_day_after_may_first(ends_on.year + 1) : add_months(ends_on, 3)
      base + 15.days
    end

    def self.corporate_tax_balance(ends_on : Time) : Time
      return date(ends_on.year + 1, 5, 15) if december_close?(ends_on)
      target = add_months(date(ends_on.year, ends_on.month, 1), 4)
      date(target.year, target.month, 15)
    end

    # Dates des acomptes d'IS comprises dans l'exercice.
    def self.corporate_tax_advances(starts_on : Time, ends_on : Time) : Array(Time)
      dates = [] of Time
      (starts_on.year..ends_on.year).each do |year|
        [3, 6, 9, 12].each do |month|
          day = date(year, month, 15)
          dates << day if starts_on <= day <= ends_on
        end
      end
      dates.first(4)
    end

    def self.vat_monthly(period_to : Time) : Time
      next_month = add_months(date(period_to.year, period_to.month, 1), 1)
      date(next_month.year, next_month.month, VAT_DAY)
    end

    def self.vat_annual(ends_on : Time) : Time
      december_close?(ends_on) ? second_business_day_after_may_first(ends_on.year + 1) : add_months(ends_on, 3)
    end

    def self.das2(year : Int32) : Time
      second_business_day_after_may_first(year + 1)
    end

    def self.greffe(ends_on : Time) : Time
      target = add_months(date(ends_on.year, ends_on.month, 1), 7)
      end_of_month(target.year, target.month)
    end

    # Périodes de TVA (mois ou trimestres civils) couvertes par l'exercice.
    def self.vat_periods(starts_on : Time, ends_on : Time, months : Int32) : Array({Time, Time})
      periods = [] of {Time, Time}
      first = date(starts_on.year, starts_on.month, 1)
      if months == 3
        first = date(first.year, ((first.month - 1) // 3) * 3 + 1, 1)
      end
      current = first
      while current <= ends_on
        last = add_months(current, months) - 1.day
        periods << {current, last} if last >= starts_on
        current = add_months(current, months)
      end
      periods
    end
  end
end
