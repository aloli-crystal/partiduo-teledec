# SPDX-License-Identifier: AGPL-3.0-or-later

module Teledec
  # Identifiants de l'API partenaire du dossier (déchiffrés le temps d'un
  # appel, jamais journalisés) : identifiant, clé, environnement
  # (`sandbox` ou `production`).
  record Credentials, login : String, api_key : String, env : String do
    def to_s(io : IO) : Nil
      io << "Teledec::Credentials(" << login << ", ***, " << env << ")"
    end

    def inspect(io : IO) : Nil
      to_s(io)
    end
  end

  # Déclaration remise au transport : `reference` est la clé
  # d'idempotence (un même dépôt rejoué ne crée pas un second dépôt chez
  # TELEDEC), `payload` le document JSON (`Teledec::Payload`), `fingerprint`
  # son empreinte SHA-256.
  record Submission, reference : String, kind : String, forms : Array(String), payload : String, fingerprint : String

  # Accusé de réception rendu par TELEDEC (PDF, en général).
  record Receipt, filename : String, content_type : String, content : Bytes

  # État d'un dépôt chez TELEDEC : `pending` (transmis, pas encore d'accusé),
  # `acknowledged` (accusé de réception de la DGFiP ou du greffe),
  # `rejected` (motif dans `reason`).
  record RemoteStatus, state : String, reason : String = "", receipt : Receipt? = nil, at : Time? = nil

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

  # Interface abstraite du partenaire EDI (ADR-007 D4, formule *API
  # Balance*) : l'extension est écrite contre elle et testée contre un
  # TELEDEC simulé (`spec/support/simulated_teledec.cr`). L'adaptateur réel
  # se branche par `Teledec::Transports.current =` quand la documentation de
  # l'API partenaire est disponible (BLOCAGES B-TDC-001).
  abstract class Transport
    # Nom affiché (« TELEDEC », « TELEDEC simulé »).
    abstract def name : String

    # Vérifie les identifiants ; lève `TransportError`
    # (`teledec.errors.transport.credentials`) s'ils sont refusés.
    abstract def check(credentials : Credentials) : Nil

    # Dépose la déclaration ; rend l'identifiant du dépôt chez TELEDEC.
    # Idempotent sur `submission.reference`.
    abstract def submit(credentials : Credentials, submission : Submission) : String

    # État d'un dépôt.
    abstract def status(credentials : Credentials, remote_id : String) : RemoteStatus
  end

  # Transport actif de l'instance. `nil` tant que l'adaptateur réel n'est
  # pas écrit (partenariat demandé le 27 septembre 2026, ADR-007 D5) :
  # l'extension prépare et contrôle les déclarations, exporte la balance
  # pour un import manuel chez TELEDEC, et laisse noter à la main le dépôt
  # et son accusé (repli, DECISIONS D-TDC-004).
  module Transports
    class_property current : Transport? = nil

    def self.available? : Bool
      !current.nil?
    end
  end
end
