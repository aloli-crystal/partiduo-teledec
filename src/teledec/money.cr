# SPDX-License-Identifier: AGPL-3.0-or-later

module Teledec
  # Montants du document transmis : texte décimal au point, deux décimales,
  # ou euros entiers (arrondi fiscal : 0,50 à l'euro supérieur). Jamais de
  # flottant.
  module Money
    ZERO = BigDecimal.new(0)

    def self.cents(value : BigDecimal) : String
      rounded = value.round(2, mode: :ties_away)
      negative = rounded < 0
      scaled = (rounded.abs * 100).to_big_i.to_s.rjust(3, '0')
      "#{negative ? "-" : ""}#{scaled[0...-2]}.#{scaled[-2..]}"
    end

    def self.euros(value : BigDecimal) : BigDecimal
      value.round(0, mode: :ties_away)
    end

    def self.euros_text(value : BigDecimal) : String
      euros(value).to_big_i.to_s
    end

    def self.parse(text : String) : BigDecimal
      BigDecimal.new(text)
    rescue ArgumentError | InvalidBigDecimalException
      ZERO
    end
  end
end
