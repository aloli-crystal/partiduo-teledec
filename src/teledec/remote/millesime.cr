# SPDX-License-Identifier: AGPL-3.0-or-later

module Teledec
  module Remote
    # Millésime des formulaires de TELEDEC (DECISIONS D-TDC6-001, règle
    # confirmée par TELEDEC le 1er octobre 2026, D-TDC9-003). Le millésime
    # est l'année de *campagne* : la DAS2 des sommes versées en 2025 et la
    # liasse de l'exercice clos le 31 décembre 2025 relèvent de la campagne
    # 2026. Sources (`.teledec-doc/`) : réponses de TELEDEC du 1er octobre
    # 2026 ; pages « Formulaires fiscaux - Millésime 2024 à 2026 » et leurs
    # paliers, guide de l'API Liasse (exercice 2024 → `#MILLESIME 2025`),
    # page des schémas JSON (`{millesime}` = « année de campagne »),
    # évolutions de janvier et février 2026 (DAS2 et TVA « millésime
    # 202601 »).
    #
    # * Liasse et DAS2 : année du *lendemain de la clôture* (clôture au
    #   31/12/2025 → 01/01/2026 → 2026 ; clôture au 30/06/2025 →
    #   01/07/2025 → 2025 ; DAS2 des sommes de 2025 → 2026).
    # * TVA (CA3, CA12 et annexes) : *aucun millésime transmis* — TELEDEC
    #   l'ignore et déduit le palier du schéma de `period.end` (3310A de
    #   février 2025 → 2025 ; 3310TIC de janvier 2026 → 202601). Le palier
    #   reste calculé ici pour choisir le schéma de validation et la table
    #   des codes : année de la période, palier en cours d'année pour une
    #   période close à partir du 1er juin 2025 (`202502`) ou du 1er juin
    #   2026 (`202602`) ; le millésime 2026 de base se nomme `202601`.
    # * Relevés d'IS (2571, 2572) : la DGFiP n'accepte plus l'ancien format
    #   dès la mise en production du nouveau (début mars) : année de
    #   l'échéance, moins un pour une échéance de janvier ou février.
    #
    # Les schémas de TELEDEC ne sont publiés qu'aux millésimes où le
    # formulaire change (`index.json` : 2571 en 2025 seulement, 2033A en
    # 2024…) : le schéma d'un dépôt est le plus récent dont le rang ne
    # dépasse pas le millésime visé (`pick`).
    module Millesime
      # Paliers réglementaires en cours d'année : année → premier jour de
      # la première période concernée (mois, jour).
      PALIERS = {2025 => {6, 1}, 2026 => {6, 1}}

      # Rang comparable d'un millésime : `2025` → `202501`, un palier
      # (`202502`) reste tel quel.
      def self.rank(value : Int32) : Int32
        value < 10_000 ? value * 100 + 1 : value
      end

      # Année de campagne d'un dépôt (champ `period.millesime` de la marque
      # blanche hors TVA, `#MILLESIME` de la liasse). `period_to` : fin de
      # période ou d'exercice ; `due_on` : échéance (`AAAA-MM-JJ`), pour les
      # relevés d'IS. TVA : année de la période (référence interne, jamais
      # transmise).
      def self.campaign(kind : String, period_to : String, due_on : String? = nil) : Int32
        finish = day(period_to)
        case kind
        when "liasse", "das2"
          # Année du lendemain de la clôture (réponses du 1er octobre 2026).
          (finish + 1.day).year
        when "is_2571", "is_2572"
          due = due_on.try { |text| day(text) } || finish
          due.month < 3 ? due.year - 1 : due.year
        else
          finish.year
        end
      end

      # Millésime visé, au rang (`rank`), palier compris : c'est lui qui
      # choisit le schéma et la table des codes de TVA.
      def self.target(kind : String, period_to : String, due_on : String? = nil) : Int32
        return palier(day(period_to)) if kind.starts_with?("vat_")
        rank(campaign(kind, period_to, due_on))
      end

      # Rang du palier de TVA d'une période close le `finish`.
      def self.palier(finish : Time) : Int32
        start = PALIERS[finish.year]?.try { |(month, first)| Time.utc(finish.year, month, first) }
        finish.year * 100 + (start && finish >= start ? 2 : 1)
      end

      # Millésime publié retenu pour `target` : le plus récent de
      # `available` dont le rang ne le dépasse pas ; `nil` s'il n'y en a pas.
      def self.pick(available : Enumerable(Int32), target : Int32) : Int32?
        available.select { |value| rank(value) <= target }.max_by? { |value| rank(value) }
      end

      private def self.day(text : String) : Time
        Time.parse(text[0, 10], "%F", Time::Location::UTC)
      end
    end
  end
end
