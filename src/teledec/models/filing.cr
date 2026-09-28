# SPDX-License-Identifier: AGPL-3.0-or-later

module Teledec
  # Dépôt d'une déclaration (ADR-007 D4) : une ligne par déclaration
  # attendue (`key` : `liasse:<exercice>`, `vat_ca3:<début>`,
  # `das2:<année>`, `is_2571:<exercice>:<n>`…). `payload` est le document
  # préparé (`Teledec::Payload`), `fingerprint` son empreinte ; `controls`
  # les contrôles de la dernière préparation (JSON). Statut : `prepared`,
  # `transmitted`, `acknowledged` (accusé en pièce jointe du socle,
  # `receipt_attachment_id`), `rejected` (motif). Un dépôt transmis ou
  # accusé ne se prépare plus (contrainte en base) ; un dépôt rejeté se
  # prépare de nouveau. Interne.
  class Filing < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :key, :string, max_size: 64, unique: true
    field :kind, :string, max_size: 16
    field :forms, :string, max_size: 64
    field :fiscal_year_id, :big_int, blank: true, null: true, index: true
    field :year, :int
    field :number, :int, default: 0
    field :period_from, :date
    field :period_to, :date
    field :due_on, :date, blank: true, null: true
    field :vat_return_id, :big_int, blank: true, null: true
    field :status, :string, max_size: 16, default: "prepared"
    field :payload, :text
    field :fingerprint, :string, max_size: 64
    field :controls, :text, blank: true, default: "[]"
    field :remote_id, :string, max_size: 128, blank: true, default: ""
    field :rejection_reason, :text, blank: true, default: ""
    field :last_error, :string, max_size: 255, blank: true, default: ""
    field :manual, :bool, default: false
    field :receipt_attachment_id, :big_int, blank: true, null: true
    field :prepared_at, :date_time
    field :prepared_by_id, :big_int, blank: true, null: true
    field :transmitted_at, :date_time, blank: true, null: true
    field :transmitted_by_id, :big_int, blank: true, null: true
    field :acknowledged_at, :date_time, blank: true, null: true
    field :rejected_at, :date_time, blank: true, null: true

    with_timestamp_fields
  end

  # Historique d'un dépôt : chaque changement de statut, avec son auteur et
  # son détail (motif de rejet, erreur du transport). Interne.
  class FilingEvent < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :filing_id, :big_int, index: true
    field :status, :string, max_size: 16
    field :detail, :text, blank: true, default: ""
    field :user_id, :big_int, blank: true, null: true
    field :created_at, :date_time
  end
end
