# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"

module Teledec
  # Document transmis à TELEDEC (formule API Balance, ADR-007 D4), neutre :
  # l'adaptateur réel le traduit dans le format du partenaire. Montants en
  # texte décimal (jamais de flottant) ; dates `AAAA-MM-JJ`. Sérialisé de
  # façon stable (ordre des champs fixe) : son empreinte SHA-256 détecte
  # toute modification entre la préparation et la transmission.
  class Payload
    include JSON::Serializable

    SCHEMA = "partiduo-teledec/1"

    # Identité de l'entreprise (société du socle).
    class Identity
      include JSON::Serializable

      getter company_name : String
      getter legal_form : String
      getter siren : String
      getter vat_number : String
      getter rcs : String
      getter share_capital : String?
      getter street : String
      getter postcode : String
      getter city : String
      getter country_code : String
      getter email : String

      def initialize(@company_name, @legal_form, @siren, @vat_number, @rcs, @share_capital, @street, @postcode,
                     @city, @country_code, @email)
      end
    end

    # Ligne de balance : mouvements de l'exercice (à-nouveaux compris) et
    # solde final en deux colonnes, avant l'écriture de clôture.
    class BalanceRow
      include JSON::Serializable

      getter account : String
      getter label : String
      getter debit : String
      getter credit : String
      getter balance_debit : String
      getter balance_credit : String

      def initialize(@account, @label, @debit, @credit, @balance_debit, @balance_credit)
      end
    end

    # Bénéficiaire de la DAS2 : identité de la fiche fournisseur, montants
    # par nature (euros entiers). Personne physique (`person`, fiche
    # fournisseur de nature `individual`) : nom, prénoms et date de
    # naissance (`AAAA-MM-JJ`, vide si inconnue) ; absents des documents
    # préparés avant cette distinction, lus alors comme une personne morale.
    class Das2Line
      include JSON::Serializable

      getter card_code : String
      getter name : String
      getter siret : String
      getter profession : String
      getter address : String
      getter postcode : String
      getter city : String
      getter country_code : String
      getter amounts : Hash(String, String)
      getter total : String
      getter? person : Bool = false
      getter last_name : String = ""
      getter first_names : String = ""
      getter birth_date : String = ""

      def initialize(@card_code, @name, @siret, @profession, @address, @postcode, @city, @country_code, @amounts, @total,
                     @person = false, @last_name = "", @first_names = "", @birth_date = "")
      end
    end

    getter schema : String = SCHEMA
    getter kind : String
    getter forms : Array(String)
    getter identity : Identity
    getter period_from : String
    getter period_to : String
    getter number : Int32
    getter balance : Array(BalanceRow)?
    getter previous_balance : Array(BalanceRow)?
    # Montants par formulaire et par case (TVA, 2035 préparée), euros
    # entiers pour la France.
    getter boxes : Hash(String, Hash(String, String))?
    getter das2 : Array(Das2Line)?
    # Données propres à la sorte (IS : montants ; greffe : confidentialité ;
    # 2035 : empreinte de la déclaration préparée).
    getter details : Hash(String, String)

    def initialize(@kind, @forms, @identity, @period_from, @period_to, @number = 0, @balance = nil,
                   @previous_balance = nil, @boxes = nil, @das2 = nil, @details = {} of String => String)
    end

    def fingerprint : String
      OpenSSL::Digest.new("SHA256").update(to_json).final.hexstring
    end
  end
end
