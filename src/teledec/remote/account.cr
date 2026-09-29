# SPDX-License-Identifier: AGPL-3.0-or-later

require "crypto/bcrypt/password"

module Teledec
  module Remote
    # Compte de l'entreprise chez TELEDEC, en marque blanche (réponses de
    # TELEDEC du 29 septembre 2026, DECISIONS D-TDC3-007) : TELEDEC le crée
    # à la transmission, sous une adresse d'utilisateur *dans le domaine
    # déclaré comme partenaire chez TELEDEC*, avec un mot de passe chiffré
    # (bcrypt, coût 12).
    #
    # * Domaine : réglage `PARTIDUO_TELEDEC_USER_DOMAIN` de l'instance,
    #   obligatoire pour l'adaptateur réel ; aucun domaine n'est écrit en
    #   dur (sans réglage, la transmission est refusée :
    #   `teledec.errors.transport.user_domain`).
    # * Adresse : `PARTIDUO_TELEDEC_USER_FORMAT` (défaut `teledec-{siren}`),
    #   partie locale qui doit contenir `{siren}` — une adresse stable par
    #   entreprise, sans collision entre dossiers.
    # * Mot de passe : aléatoire, oublié aussitôt ; seul son haché bcrypt est
    #   gardé (paramètres de l'extension) et part chez TELEDEC. L'utilisateur
    #   n'en a pas besoin : il ouvre sa déclaration par le lien que rend
    #   TELEDEC.
    module Account
      DOMAIN_VARIABLE = "PARTIDUO_TELEDEC_USER_DOMAIN"
      FORMAT_VARIABLE = "PARTIDUO_TELEDEC_USER_FORMAT"
      DEFAULT_FORMAT  = "teledec-{siren}"
      BCRYPT_COST     = 12

      DOMAIN = /\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\z/
      LOCAL  = /\A[a-z0-9]([a-z0-9._+-]*[a-z0-9])?\z/

      # Domaine réglé et valide, sinon `nil`.
      def self.domain(value : String? = ENV[DOMAIN_VARIABLE]?) : String?
        clean = value.to_s.strip.downcase.lchop('@')
        clean if clean.matches?(DOMAIN)
      end

      # Format de la partie locale (`{siren}` obligatoire), sinon `nil`.
      def self.format(value : String? = ENV[FORMAT_VARIABLE]?) : String?
        clean = value.to_s.strip.downcase.presence || DEFAULT_FORMAT
        clean if clean.includes?("{siren}") && clean.gsub("{siren}", "000000000").matches?(LOCAL)
      end

      # Adresse de l'entreprise de SIREN `siren` ; `nil` sans domaine, avec
      # un format invalide ou un SIREN qui n'a pas neuf chiffres.
      def self.email(siren : String, domain : String? = self.domain, format : String? = self.format) : String?
        return unless siren.matches?(/\A\d{9}\z/)
        host = domain || return
        local = format || return
        "#{local.gsub("{siren}", siren)}@#{host}"
      end

      # Haché bcrypt (coût 12) d'un mot de passe aléatoire, aussitôt oublié.
      def self.new_password_hash : String
        Crypto::Bcrypt::Password.create(Random::Secure.urlsafe_base64(24), cost: BCRYPT_COST).to_s
      end
    end
  end
end
