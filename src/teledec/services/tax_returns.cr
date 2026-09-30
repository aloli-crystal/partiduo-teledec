# SPDX-License-Identifier: AGPL-3.0-or-later

module Teledec
  # Transmission de la 2035 préparée par le module `liberal` (DECISIONS
  # D-LIB2-003) : l'exercice se fige quand sa 2035 est transmise. L'extension
  # ne l'écrit pas dans le module (aucun appel de commande, ADR-006 D3) : elle
  # publie, dans la transaction qui note le dépôt,
  #
  # * `tax_return.transmitted` (`form` `2035`, `year`, `reference`,
  #   `fingerprint` : empreinte de la 2035 jointe) quand le dépôt est
  #   transmis, par l'API de TELEDEC ou noté à la main ;
  # * `tax_return.rejected` (mêmes `form`, `year`, `reference`) quand ce
  #   dépôt est rejeté : l'exercice redevient modifiable, sauf s'il est
  #   clôturé.
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
