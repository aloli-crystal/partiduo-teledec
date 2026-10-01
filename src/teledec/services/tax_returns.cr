# SPDX-License-Identifier: AGPL-3.0-or-later

module Teledec
  # Transmission de la 2035 préparée par le module `liberal` (DECISIONS
  # D-LIB2-003, D-LIB5-002) : l'exercice se verrouille quand sa 2035 est
  # transmise. L'extension
  # ne l'écrit pas dans le module (aucun appel de commande, ADR-006 D3) : elle
  # publie, dans la transaction qui note le dépôt,
  #
  # * `tax_return.transmitted` (`form` `2035`, `year`, `reference`,
  #   `fingerprint` : empreinte de la 2035 jointe) quand le dépôt est
  #   transmis, par l'API de TELEDEC ou noté à la main ;
  # * `tax_return.rejected` (mêmes `form`, `year`, `reference`) quand ce
  #   dépôt est rejeté : le verrou est levé, l'exercice redevient clôturé
  #   (réversible) pour correction et nouvel envoi (D-LIB5-002).
  #
  # La 2035 se transmet sur un exercice *clôturé* (D-LIB5-003) : tant que
  # l'exercice est ouvert, la préparation porte un contrôle bloquant
  # (`teledec.controls.liberal_year_open`) et la transmission, par l'API ou
  # notée à la main, est refusée (`teledec.errors.filing.liberal_year_open`).
  #
  # Seuls les dépôts qui joignent la 2035 du module (`tax_return_fingerprint`
  # dans les détails : liasse BNC, avec ou sans la Comptabilité) sont
  # concernés. Le module `liberal`, s'il est actif, s'y abonne ; sans lui,
  # l'événement n'a pas d'abonné.
  module TaxReturns
    FORM = "2035"

    def self.concerned?(filing : Filing) : Bool
      filing.kind == "liasse" && !fingerprint(filing).empty?
    end

    # Référence du dépôt, la même à la transmission et au rejet.
    def self.reference(filing : Filing) : String
      "teledec:#{filing.id}"
    end

    # Refus de transmettre la 2035 d'un exercice encore ouvert (lu par le
    # contrat du module ; module inactif depuis la préparation : rien à
    # exiger).
    def self.open_year_errors(filing : Filing) : Array(Partiduo::Api::FieldError)
      return [] of Partiduo::Api::FieldError unless concerned?(filing)
      return [] of Partiduo::Api::FieldError unless Partiduo::Api::Liberal.year(Partiduo::Api::Actor.system, (filing.year || 0).to_i32).open?
      [Partiduo::Api::FieldError.base("teledec.errors.filing.liberal_year_open", {"year" => filing.year.to_s})]
    rescue Partiduo::Api::ModuleDisabled
      [] of Partiduo::Api::FieldError
    end

    def self.transmitted(filing : Filing, user_id : Int64?) : Nil
      return unless concerned?(filing)
      Partiduo::Events.publish("tax_return.transmitted", payload(filing).merge({"fingerprint" => fingerprint(filing)}),
        actor_user_id: user_id)
    end

    def self.rejected(filing : Filing, user_id : Int64?) : Nil
      return unless concerned?(filing)
      Partiduo::Events.publish("tax_return.rejected", payload(filing), actor_user_id: user_id)
    end

    private def self.payload(filing : Filing) : Hash(String, String)
      {"form" => FORM, "year" => filing.year.to_s, "reference" => reference(filing)}
    end

    private def self.fingerprint(filing : Filing) : String
      Payload.from_json(filing.payload.to_s).details["tax_return_fingerprint"]? || ""
    end
  end
end
