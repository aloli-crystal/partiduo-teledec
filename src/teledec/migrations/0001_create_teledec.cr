# SPDX-License-Identifier: AGPL-3.0-or-later

# Tables de l'extension TELEDEC (ADR-007 D4) : paramètres (identifiants de
# l'API chiffrés), dépôts et leur historique.
#
# Intégrité en base : une seule ligne de paramètres ; régimes, sortes,
# statuts et environnements contrôlés ; un dépôt transmis a son identifiant
# chez TELEDEC (sauf dépôt noté à la main), un dépôt rejeté son motif ;
# l'accusé est une pièce jointe du socle (clé étrangère vers
# `core_attachment`, ADR-006 D1) ; un dépôt transmis ou accusé garde son
# document (déclencheur `teledec_filing_guard`).
class Migration::Teledec::V0001 < Marten::Migration
  depends_on :core, "0003_period_guard_fiscal_year_move"

  CONSTRAINTS = [
    {<<-SQL, "SELECT 1"},
      ALTER TABLE teledec_settings
        ADD CONSTRAINT teledec_settings_key_check CHECK (key = 'default'),
        ADD CONSTRAINT teledec_settings_tax_system_check CHECK (tax_system IN ('', 'is_rsi', 'is_rn', 'bic_rsi', 'bic_rn', 'bnc', 'sci')),
        ADD CONSTRAINT teledec_settings_vat_system_check CHECK (vat_system IN ('', 'ca3_monthly', 'ca3_quarterly', 'ca12', 'none')),
        ADD CONSTRAINT teledec_settings_env_check CHECK (env IN ('sandbox', 'production')),
        ADD CONSTRAINT teledec_settings_threshold_check CHECK (das2_threshold >= 0)
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE teledec_filing
        ADD CONSTRAINT teledec_filing_kind_check CHECK (kind IN
          ('liasse', 'vat_ca3', 'vat_ca12', 'das2', 'is_2571', 'is_2572', 'greffe')),
        ADD CONSTRAINT teledec_filing_status_check CHECK (status IN ('prepared', 'transmitted', 'acknowledged', 'rejected')),
        ADD CONSTRAINT teledec_filing_period_check CHECK (period_from <= period_to),
        ADD CONSTRAINT teledec_filing_remote_check CHECK (status = 'prepared' OR manual OR remote_id <> ''),
        ADD CONSTRAINT teledec_filing_rejected_check CHECK (status <> 'rejected' OR rejection_reason <> ''),
        ADD CONSTRAINT teledec_filing_receipt_fk FOREIGN KEY (receipt_attachment_id) REFERENCES core_attachment (id)
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE teledec_filing_event
        ADD CONSTRAINT teledec_filing_event_status_check CHECK (status IN
          ('prepared', 'transmitted', 'acknowledged', 'rejected', 'error')),
        ADD CONSTRAINT teledec_filing_event_filing_fk FOREIGN KEY (filing_id) REFERENCES teledec_filing (id) ON DELETE CASCADE
      SQL
    {<<-SQL, "DROP FUNCTION IF EXISTS teledec_filing_guard() CASCADE"},
      CREATE FUNCTION teledec_filing_guard() RETURNS trigger AS $$
      BEGIN
        IF TG_OP = 'DELETE' THEN
          IF OLD.status IN ('transmitted', 'acknowledged') THEN
            RAISE EXCEPTION 'teledec: dépôt % transmis, intangible', OLD.key;
          END IF;
          RETURN OLD;
        END IF;
        IF OLD.status IN ('transmitted', 'acknowledged')
           AND (NEW.payload IS DISTINCT FROM OLD.payload OR NEW.fingerprint IS DISTINCT FROM OLD.fingerprint
                OR NEW.key IS DISTINCT FROM OLD.key OR NEW.kind IS DISTINCT FROM OLD.kind) THEN
          RAISE EXCEPTION 'teledec: dépôt % transmis, document intangible', OLD.key;
        END IF;
        IF OLD.status = 'acknowledged' AND NEW.status <> 'acknowledged' THEN
          RAISE EXCEPTION 'teledec: dépôt % accusé, statut définitif', OLD.key;
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
      SQL
    {"CREATE TRIGGER teledec_filing_guard BEFORE UPDATE OR DELETE ON teledec_filing " \
     "FOR EACH ROW EXECUTE FUNCTION teledec_filing_guard()", "SELECT 1"},
  ]

  def plan
    create_table :teledec_settings do
      column :id, :big_int, primary_key: true, auto: true
      column :key, :string, max_size: 16, unique: true, default: "default"
      column :tax_system, :string, max_size: 16, default: ""
      column :vat_system, :string, max_size: 16, default: ""
      column :greffe, :bool, default: false
      column :das2_accounts, :text, default: ""
      column :das2_threshold, :decimal, max_digits: 20, decimal_places: 2, default: "1200.0"
      column :env, :string, max_size: 16, default: "sandbox"
      column :login, :string, max_size: 255, default: ""
      column :api_key, :text, default: ""
      column :checked_at, :date_time, null: true
      column :updated_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :teledec_filing do
      column :id, :big_int, primary_key: true, auto: true
      column :key, :string, max_size: 64, unique: true
      column :kind, :string, max_size: 16
      column :forms, :string, max_size: 64
      column :fiscal_year_id, :big_int, null: true, index: true
      column :year, :int
      column :number, :int, default: 0
      column :period_from, :date
      column :period_to, :date
      column :due_on, :date, null: true
      column :vat_return_id, :big_int, null: true
      column :status, :string, max_size: 16, default: "prepared"
      column :payload, :text
      column :fingerprint, :string, max_size: 64
      column :controls, :text, default: "[]"
      column :remote_id, :string, max_size: 128, default: ""
      column :rejection_reason, :text, default: ""
      column :last_error, :string, max_size: 255, default: ""
      column :manual, :bool, default: false
      column :receipt_attachment_id, :big_int, null: true
      column :prepared_at, :date_time
      column :prepared_by_id, :big_int, null: true
      column :transmitted_at, :date_time, null: true
      column :transmitted_by_id, :big_int, null: true
      column :acknowledged_at, :date_time, null: true
      column :rejected_at, :date_time, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :teledec_filing_event do
      column :id, :big_int, primary_key: true, auto: true
      column :filing_id, :big_int, index: true
      column :status, :string, max_size: 16
      column :detail, :text, default: ""
      column :user_id, :big_int, null: true
      column :created_at, :date_time
    end

    CONSTRAINTS.each { |(forward, backward)| execute(forward, backward) }
  end
end
