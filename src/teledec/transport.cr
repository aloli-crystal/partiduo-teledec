# SPDX-License-Identifier: AGPL-3.0-or-later

module Teledec
  # Identifiants de l'API partenaire du dossier (déchiffrés le temps d'un
  # appel, jamais journalisés) : identifiant et secret du client OAuth2
  # (`login`, `api_key`), environnement (`sandbox` : stage de TELEDEC,
  # `production`), email du compte TELEDEC de l'entreprise (`email`,
  # identifiant de ses déclarations chez TELEDEC) et SIRET de
  # l'établissement déclarant (`siret`, facultatif).
  record Credentials, login : String, api_key : String, env : String, email : String = "", siret : String = "" do
    def to_s(io : IO) : Nil
      io << "Teledec::Credentials(" << login << ", ***, " << env << ")"
    end

    def inspect(io : IO) : Nil
      to_s(io)
    end
  end

  # Déclaration remise au transport : `reference` est la clé
  # d'idempotence (un même dépôt rejoué ne crée pas un second dépôt chez
  # TELEDEC ; renvoyée par TELEDEC dans ses rappels), `payload` le document
  # JSON (`Teledec::Payload`), `fingerprint` son empreinte SHA-256. `due_on`
  # (échéance, `AAAA-MM-JJ`), `year_end` (clôture de l'exercice,
  # `AAAA-MM-JJ`) et `callback_url` (adresse de rappel de l'instance)
  # complètent le document pour l'API.
  record Submission, reference : String, kind : String, forms : Array(String), payload : String, fingerprint : String,
    due_on : String? = nil, year_end : String? = nil, callback_url : String? = nil

  # Dépôt accepté par TELEDEC : `remote_id` permet d'en relever l'état,
  # `url` est la page à ouvrir par l'utilisateur pour vérifier et envoyer
  # (vide si TELEDEC n'en rend pas), `remote_status` l'état brut chez
  # TELEDEC.
  record Submitted, remote_id : String, url : String = "", remote_status : String = ""

  # Accusé de réception rendu par TELEDEC (PDF, en général).
  record Receipt, filename : String, content_type : String, content : Bytes

  # État d'un dépôt chez TELEDEC : `pending` (transmis, pas encore d'accusé),
  # `acknowledged` (accusé de réception de la DGFiP ou du greffe),
  # `rejected` (motif dans `reason`). `remote_status` : état brut chez
  # TELEDEC, normalisé en minuscules (`notcompleted`, `readytobesent`,
  # `sent`, `ok`…) ; `declaration_id` : identifiant de la déclaration chez
  # TELEDEC s'il est connu.
  record RemoteStatus, state : String, reason : String = "", receipt : Receipt? = nil, at : Time? = nil,
    remote_status : String = "", declaration_id : String = ""

  # Erreur du transport : `key` est une clé i18n (`teledec.errors.transport.*`)
  # traduite à l'affichage ; le message technique ne contient jamais de
  # secret.
  class TransportError < Exception
    getter key : String
    getter params : Hash(String, String)

    def initialize(@key : String, @params : Hash(String, String) = {} of String => String, message : String? = nil)
      super(message || @key)
    end
  end

  # Interface abstraite du partenaire EDI (ADR-007 D4) : l'extension est
  # écrite contre elle. L'adaptateur réel est `Teledec::HttpTransport`
  # (API partenaire de TELEDEC, `src/teledec/remote/`) ; les specs le
  # branchent sur un TELEDEC simulé qui reproduit les échanges HTTP
  # (`spec/support/simulated_teledec.cr`).
  abstract class Transport
    # Nom affiché (« TELEDEC », « TELEDEC simulé »).
    abstract def name : String

    # Vérifie les identifiants ; lève `TransportError`
    # (`teledec.errors.transport.credentials`) s'ils sont refusés.
    abstract def check(credentials : Credentials) : Nil

    # Dépose la déclaration. Idempotent sur `submission.reference` et sur
    # la période déclarée.
    abstract def submit(credentials : Credentials, submission : Submission) : Submitted

    # État d'un dépôt. `reference` : référence de l'envoi en cours
    # (`Submission#reference`) ; un compte-rendu d'un envoi précédent (autre
    # référence) ne fait pas foi.
    abstract def status(credentials : Credentials, remote_id : String, reference : String = "") : RemoteStatus
  end

  # Transport actif de l'instance : l'adaptateur de l'API partenaire de
  # TELEDEC. `nil` désactive la transmission directe : l'extension prépare
  # et contrôle les déclarations, exporte la balance pour un import manuel
  # chez TELEDEC et laisse noter à la main le dépôt et son accusé (repli,
  # DECISIONS D-TDC-004).
  module Transports
    @@current : Transport? = nil
    @@initialised = false

    def self.current : Transport?
      unless @@initialised
        @@initialised = true
        @@current = HttpTransport.new
      end
      @@current
    end

    def self.current=(transport : Transport?) : Transport?
      @@initialised = true
      @@current = transport
    end

    def self.available? : Bool
      !current.nil?
    end
  end
end
