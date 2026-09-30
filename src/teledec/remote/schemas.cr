# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"

module Teledec
  module Remote
    # Schémas JSON officiels de TELEDEC gardés dans un dossier de l'instance
    # (`GET /service/api-doc/schemas…` : `index.json`, `envelope.json`,
    # `<formulaire>-<millésime>.json`), pour valider chaque document avant
    # de l'envoyer (DECISIONS D-TDC6-002, D-TDC6-003). Documents de TELEDEC :
    # jamais versionnés dans le dépôt ; l'opérateur les télécharge et règle
    # `PARTIDUO_TELEDEC_SCHEMAS_DIR`. Sans réglage, rien n'est validé.
    #
    # Le schéma d'un dépôt est celui du formulaire au millésime publié le
    # plus récent qui ne dépasse pas le millésime visé
    # (`Millesime.pick`) ; un formulaire sans schéma (la CA3 `3310CA3`
    # n'est pas publiée) n'est validé que sur l'enveloppe (`auth`,
    # `identity`, `period`).
    class Schemas
      VARIABLE = "PARTIDUO_TELEDEC_SCHEMAS_DIR"

      # Résultat d'une validation : formulaire, millésime du schéma employé
      # (`nil` : enveloppe seule, ou rien si l'enveloppe manque aussi),
      # écarts.
      record Outcome, form : String, millesime : Int32?, violations : Array(JsonSchema::Violation),
        checked : Bool = true do
        def ok? : Bool
          violations.empty?
        end

        # Nom du schéma employé (`DAS2-2026`, `envelope`).
        def schema_name : String
          millesime.try { |value| "#{form}-#{value}" } || "envelope"
        end
      end

      getter dir : String
      @cache = {} of String => JSON::Any?
      @index : Hash(String, Array(Int32))? = nil
      @mutex = Mutex.new

      # Schémas du dossier réglé (`PARTIDUO_TELEDEC_SCHEMAS_DIR` par
      # défaut) ; `nil` sans réglage.
      def self.from(dir : String? = ENV[VARIABLE]?) : Schemas?
        clean = dir.to_s.strip
        clean.empty? ? nil : new(clean)
      end

      def initialize(@dir : String)
      end

      # Le dossier existe-t-il ?
      def present? : Bool
        Dir.exists?(dir)
      end

      # Millésimes publiés d'un formulaire : `index.json`, à défaut les
      # fichiers du dossier.
      def available(form : String) : Array(Int32)
        index[form]? || [] of Int32
      end

      # Millésime du schéma retenu pour `form` et le millésime visé `target`
      # (rang, `Millesime.rank`) ; `nil` sans schéma.
      def pick(form : String, target : Int32) : Int32?
        Millesime.pick(available(form), target)
      end

      def schema(form : String, millesime : Int32) : JSON::Any?
        load("#{form}-#{millesime}.json")
      end

      def envelope : JSON::Any?
        load("envelope.json")
      end

      # Document complet de la marque blanche : schéma du formulaire s'il
      # est publié, sinon enveloppe seule ; rien si l'enveloppe manque
      # aussi (`checked` faux).
      def check_document(document : JSON::Any, form : String, target : Int32) : Outcome
        if millesime = pick(form, target)
          if found = schema(form, millesime)
            return Outcome.new(form, millesime, JsonSchema.validate(found, document))
          end
        end
        found = envelope || return Outcome.new(form, nil, [] of JsonSchema::Violation, checked: false)
        Outcome.new(form, nil, JsonSchema.validate(found, document))
      end

      # Bloc d'un formulaire joint à la liasse (`zones_formulaires` de l'API
      # Balance, que ces schémas couvrent bloc par bloc, pas le texte de la
      # balance) ; `checked` faux sans schéma du formulaire.
      def check_block(form : String, block : JSON::Any, target : Int32) : Outcome
        millesime = pick(form, target)
        rules = millesime.try { |value| schema(form, value) }.try(&.["properties"]?).try(&.[form]?)
        return Outcome.new(form, nil, [] of JsonSchema::Violation, checked: false) unless millesime && rules
        Outcome.new(form, millesime, JsonSchema.validate(rules, block, "$.zones_formulaires.#{form}"))
      end

      private def index : Hash(String, Array(Int32))
        @mutex.synchronize do
          @index ||= read_index
        end
      end

      private def read_index : Hash(String, Array(Int32))
        found = Hash(String, Array(Int32)).new
        if listed = read("index.json")
          (listed["formulaires"]?.try(&.as_a?) || [] of JSON::Any).each do |item|
            form = item["formId"]?.try(&.as_s?) || next
            found[form] = (item["millesimes"]?.try(&.as_a?) || [] of JSON::Any).compact_map(&.as_i?)
          end
          return found
        end
        Dir.glob(File.join(dir, "*-*.json")).each do |path|
          name = File.basename(path, ".json")
          form, _, year = name.rpartition('-')
          value = year.to_i? || next
          (found[form] ||= [] of Int32) << value
        end
        found
      end

      private def load(name : String) : JSON::Any?
        @mutex.synchronize do
          return @cache[name] if @cache.has_key?(name)
          @cache[name] = read(name)
        end
      end

      private def read(name : String) : JSON::Any?
        JSON.parse(File.read(File.join(dir, name)))
      rescue File::Error | JSON::ParseException
        nil
      end
    end
  end
end
