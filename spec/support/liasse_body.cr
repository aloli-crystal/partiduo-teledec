# SPDX-License-Identifier: AGPL-3.0-or-later

module Teledec
  module SpecSupport
    # Corps d'une liasse (API Balance) découpé en ses trois sections, comme
    # TELEDEC le lit (D-TDC7-001) : identification (`#CLE valeur`), lignes
    # de balance, puis section JSON, de la première ligne qui commence par
    # `{` à la fin du corps.
    record LiasseBody, header : Array(String), balance : Array(String), json : String? do
      def self.parse(body : String) : LiasseBody
        head, brace, rest = body.partition(/^\{/m)
        lines = head.lines
        header = lines.take_while(&.starts_with?('#'))
        new(header, lines[header.size..], brace.empty? ? nil : brace + rest)
      end

      # Section JSON analysée (`JSON.parse`) ; erreur si elle est absente.
      def document : JSON::Any
        JSON.parse(json || raise "section JSON absente de la liasse")
      end

      def zones : JSON::Any
        document["zones_formulaires"]
      end
    end
  end
end
