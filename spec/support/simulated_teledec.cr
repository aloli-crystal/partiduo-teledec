# SPDX-License-Identifier: AGPL-3.0-or-later

module Teledec
  # TELEDEC simulé pour les specs (ADR-007 D4) : identifiants de test,
  # dépôts idempotents sur la référence, accusés et rejets programmés,
  # pannes à la demande. Aucun appel réseau.
  class SimulatedTeledec < Transport
    LOGIN   = "cabinet-test"
    API_KEY = "cle-de-test-0123456789"

    record Deposit, remote_id : String, submission : Submission, credentials_env : String

    getter deposits = {} of String => Deposit
    getter states = {} of String => RemoteStatus
    property failure : String? = nil
    getter calls = 0

    def name : String
      "TELEDEC simulé"
    end

    def check(credentials : Credentials) : Nil
      @calls += 1
      unless credentials.login == LOGIN && credentials.api_key == API_KEY
        raise TransportError.new("teledec.errors.transport.credentials")
      end
    end

    def submit(credentials : Credentials, submission : Submission) : String
      check(credentials)
      if key = failure
        raise TransportError.new(key, {"reason" => "formulaire incomplet"})
      end
      JSON.parse(submission.payload) # document lisible
      if existing = deposits.values.find(&.submission.reference.==(submission.reference))
        return existing.remote_id
      end
      remote_id = "TD-#{(deposits.size + 1).to_s.rjust(6, '0')}"
      deposits[remote_id] = Deposit.new(remote_id, submission, credentials.env)
      remote_id
    end

    def status(credentials : Credentials, remote_id : String) : RemoteStatus
      check(credentials)
      states[remote_id]? || RemoteStatus.new("pending")
    end

    # Accusé de réception de la DGFiP pour un dépôt.
    def acknowledge(remote_id : String) : Nil
      pdf = "%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n"
      states[remote_id] = RemoteStatus.new("acknowledged",
        receipt: Receipt.new("accuse-#{remote_id}.pdf", "application/pdf", pdf.to_slice), at: Time.utc(2027, 5, 10))
    end

    def reject(remote_id : String, reason : String) : Nil
      states[remote_id] = RemoteStatus.new("rejected", reason: reason, at: Time.utc(2027, 5, 11))
    end
  end
end
