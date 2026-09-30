# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"

module Teledec
  module Remote
    # Validation d'un document JSON contre un schéma JSON (draft-07), en
    # Crystal pur, réduite au sous-ensemble qu'emploient les schémas
    # publiés par TELEDEC (relevé sur les 127 fichiers : `type`,
    # `properties`, `required`, `additionalProperties`, `items`, `format`
    # — `date`, `date-time`, `email` —, `minimum`, `maximum`, `minLength`),
    # plus quelques mots-clés voisins (`enum`, `const`, `pattern`,
    # `maxLength`, `exclusiveMinimum`, `exclusiveMaximum`, `minItems`,
    # `maxItems`). Les annotations (`description`, `title`, `$schema`,
    # `x-teledec-*`) sont ignorées ; `KEYWORDS` liste tout ce qui est lu.
    #
    # Chaque écart porte le chemin JSON de la valeur fautive (`$.DAS2.
    # repetitionDAS2TV[0].AI`) et un code traduit par
    # `teledec.schema.<code>` (DECISIONS D-TDC6-002).
    module JsonSchema
      # Mots-clés interprétés.
      KEYWORDS = %w[type properties required additionalProperties items format minimum maximum exclusiveMinimum
        exclusiveMaximum minLength maxLength enum const pattern minItems maxItems]
      # Mots-clés sans effet sur la validation.
      ANNOTATIONS = %w[$schema $id title description default examples]

      # Écart : chemin de la valeur, code (`type`, `required`, `unknown`,
      # `format`, `minimum`…), paramètres du message.
      record Violation, path : String, code : String, params : Hash(String, String) = {} of String => String do
        def to_s(io : IO) : Nil
          io << path << " : " << code
          params.each { |name, value| io << ' ' << name << '=' << value }
        end
      end

      DATE      = /\A(\d{4})-(\d{2})-(\d{2})\z/
      DATE_TIME = /\A(\d{4})-(\d{2})-(\d{2})T([01]\d|2[0-3]):([0-5]\d):([0-5]\d|60)(\.\d+)?(Z|[+-]([01]\d|2[0-3]):[0-5]\d)?\z/i
      EMAIL     = /\A[^@\s]+@[^@\s]+\.[^@\s.]+\z/

      # Écarts de `value` au schéma `schema` (vide si conforme).
      def self.validate(schema : JSON::Any, value : JSON::Any, path : String = "$") : Array(Violation)
        violations = [] of Violation
        check(schema, value, path, violations)
        violations
      end

      # Mots-clés d'un schéma (et de ses sous-schémas) que ce validateur
      # n'interprète pas, hors annotations : doit être vide pour les
      # schémas de TELEDEC.
      def self.unsupported(schema : JSON::Any) : Array(String)
        found = Set(String).new
        collect_unsupported(schema, found)
        found.to_a.sort!
      end

      private def self.collect_unsupported(schema : JSON::Any, found : Set(String)) : Nil
        hash = schema.as_h? || return
        hash.each_key do |name|
          next if KEYWORDS.includes?(name) || ANNOTATIONS.includes?(name) || name.starts_with?("x-")
          found << name
        end
        hash["properties"]?.try(&.as_h?).try(&.each_value { |child| collect_unsupported(child, found) })
        hash["additionalProperties"]?.try { |child| collect_unsupported(child, found) }
        items = hash["items"]?
        if list = items.try(&.as_a?)
          list.each { |child| collect_unsupported(child, found) }
        elsif items
          collect_unsupported(items, found)
        end
      end

      private def self.check(schema : JSON::Any, value : JSON::Any, path : String, violations : Array(Violation)) : Nil
        case raw = schema.raw
        when Bool
          violations << Violation.new(path, "unknown") unless raw
          return
        when Hash
        else
          return
        end
        rules = schema.as_h
        if expected = rules["type"]?
          names = expected.as_a?.try(&.map(&.as_s)) || [expected.as_s]
          unless names.any? { |name| type?(name, value) }
            violations << Violation.new(path, "type", {"expected" => names.join(", "), "actual" => type_name(value)})
            return
          end
        end
        enumeration(rules, value, path, violations)
        case raw_value = value.raw
        when String
          string(rules, raw_value, path, violations)
        when Int64, Float64
          number(rules, raw_value.to_f64, path, violations)
        when Hash(String, JSON::Any)
          object(rules, raw_value, path, violations)
        when Array(JSON::Any)
          array(rules, raw_value, path, violations)
        end
      end

      private def self.enumeration(rules : Hash(String, JSON::Any), value : JSON::Any, path : String,
                                   violations : Array(Violation)) : Nil
        if allowed = rules["enum"]?.try(&.as_a?)
          unless allowed.includes?(value)
            violations << Violation.new(path, "enum", {"allowed" => allowed.map(&.to_json).join(", ")})
          end
        end
        if constant = rules["const"]?
          violations << Violation.new(path, "enum", {"allowed" => constant.to_json}) unless constant == value
        end
      end

      private def self.string(rules : Hash(String, JSON::Any), text : String, path : String,
                              violations : Array(Violation)) : Nil
        if format = rules["format"]?.try(&.as_s?)
          violations << Violation.new(path, "format", {"expected" => format}) unless format?(format, text)
        end
        limit(rules, "minLength", path, violations, "min_length") { |bound| text.size >= bound }
        limit(rules, "maxLength", path, violations, "max_length") { |bound| text.size <= bound }
        if pattern = rules["pattern"]?.try(&.as_s?)
          matched = begin
            Regex.new(pattern).matches?(text)
          rescue ArgumentError
            true # motif illisible : pas d'écart inventé
          end
          violations << Violation.new(path, "pattern", {"pattern" => pattern}) unless matched
        end
      end

      private def self.number(rules : Hash(String, JSON::Any), number : Float64, path : String,
                              violations : Array(Violation)) : Nil
        limit(rules, "minimum", path, violations, "minimum") { |bound| number >= bound }
        limit(rules, "maximum", path, violations, "maximum") { |bound| number <= bound }
        limit(rules, "exclusiveMinimum", path, violations, "minimum") { |bound| number > bound }
        limit(rules, "exclusiveMaximum", path, violations, "maximum") { |bound| number < bound }
      end

      private def self.object(rules : Hash(String, JSON::Any), hash : Hash(String, JSON::Any), path : String,
                              violations : Array(Violation)) : Nil
        properties = rules["properties"]?.try(&.as_h?) || {} of String => JSON::Any
        (rules["required"]?.try(&.as_a?) || [] of JSON::Any).each do |name|
          key = name.as_s
          violations << Violation.new(child(path, key), "required") unless hash.has_key?(key)
        end
        extra = rules["additionalProperties"]?
        hash.each do |key, item|
          if sub = properties[key]?
            check(sub, item, child(path, key), violations)
          elsif extra
            check(extra, item, child(path, key), violations)
          end
        end
      end

      private def self.array(rules : Hash(String, JSON::Any), list : Array(JSON::Any), path : String,
                             violations : Array(Violation)) : Nil
        limit(rules, "minItems", path, violations, "min_items") { |bound| list.size >= bound }
        limit(rules, "maxItems", path, violations, "max_items") { |bound| list.size <= bound }
        items = rules["items"]? || return
        if tuple = items.as_a?
          list.each_with_index { |item, index| tuple[index]?.try { |sub| check(sub, item, "#{path}[#{index}]", violations) } }
        else
          list.each_with_index { |item, index| check(items, item, "#{path}[#{index}]", violations) }
        end
      end

      # Borne numérique `keyword` du schéma : écart `code` si le bloc la
      # juge dépassée.
      private def self.limit(rules : Hash(String, JSON::Any), keyword : String, path : String,
                             violations : Array(Violation), code : String, & : Float64 -> Bool) : Nil
        bound = rules[keyword]?.try { |item| item.as_i64?.try(&.to_f64) || item.as_f? } || return
        return if yield bound
        shown = bound == bound.round ? bound.to_i64.to_s : bound.to_s
        violations << Violation.new(path, code, {"limit" => shown})
      end

      # Chemin d'une propriété : notation pointée, entre crochets si le nom
      # n'est pas un identifiant.
      def self.child(path : String, key : String) : String
        key.matches?(/\A[A-Za-z0-9_]+\z/) ? "#{path}.#{key}" : "#{path}[#{key.to_json}]"
      end

      def self.type?(name : String, value : JSON::Any) : Bool
        raw = value.raw
        case name
        when "string"  then raw.is_a?(String)
        when "integer" then raw.is_a?(Int64) || (raw.is_a?(Float64) && raw == raw.round && raw.finite?)
        when "number"  then raw.is_a?(Int64) || raw.is_a?(Float64)
        when "boolean" then raw.is_a?(Bool)
        when "object"  then raw.is_a?(Hash)
        when "array"   then raw.is_a?(Array)
        when "null"    then raw.nil?
        else                true # type inconnu : pas d'écart inventé
        end
      end

      def self.type_name(value : JSON::Any) : String
        case raw = value.raw
        when String  then "string"
        when Int64   then "integer"
        when Float64 then "number"
        when Bool    then "boolean"
        when Hash    then "object"
        when Array   then "array"
        when Nil     then "null"
        else              raw.class.name
        end
      end

      # Formats reconnus : `date` (AAAA-MM-JJ, date réelle), `date-time`
      # (RFC 3339 ; décalage horaire facultatif, TELEDEC exigeant l'heure
      # française sans décalage pour `auth.timestamp`), `email`. Un autre
      # format n'est pas contrôlé.
      def self.format?(format : String, text : String) : Bool
        case format
        when "date"
          (match = DATE.match(text)) ? real_day?(match[1].to_i, match[2].to_i, match[3].to_i) : false
        when "date-time"
          (match = DATE_TIME.match(text)) ? real_day?(match[1].to_i, match[2].to_i, match[3].to_i) : false
        when "email"
          text.matches?(EMAIL)
        else
          true
        end
      end

      private def self.real_day?(year : Int32, month : Int32, day : Int32) : Bool
        1 <= month <= 12 && 1 <= day <= Time.days_in_month(year, month)
      end
    end
  end
end
