# SPDX-License-Identifier: AGPL-3.0-or-later

module Teledec
  module Ui
    # Ligne présentée à un gabarit : textes déjà mis en forme, par nom
    # (un grand `Hash` n'est pas lu par les gabarits Marten, BLOCAGES
    # B-EINV-001).
    class Row
      include Marten::Template::Object

      getter values : Hash(String, String?)

      def initialize(@values : Hash(String, String?))
      end

      def [](key : String) : String?
        values[key]?
      end

      def resolve_template_attribute(key : String)
        values[key]?
      end
    end

    def self.row(values : Hash(String, String?)) : Row
      Row.new(values)
    end

    def self.row(values : Hash(String, String)) : Row
      Row.new(values.transform_values(&.as(String?)))
    end

    def self.url(name : String, **params) : String
      Marten.routes.reverse("teledec:#{name}", **params)
    end

    # Classe Bulma d'un statut.
    def self.status_class(status : String?) : String
      case status
      when "acknowledged" then "is-success"
      when "transmitted"  then "is-info"
      when "rejected"     then "is-danger"
      when "prepared"     then "is-warning"
      else                     "is-light"
      end
    end

    module Present
      alias Api = Teledec::Api

      def self.forms(forms : Array(String)) : String
        forms.join(", ")
      end

      def self.control(control : Api::ControlView, fmt : PartiduoUi::Format) : Row
        error = Partiduo::Api::FieldError.new(Partiduo::Api::FieldError::BASE, control.key, control.params)
        Ui.row({"message" => fmt.message(error), "error" => control.error? ? "1" : nil, "key" => control.key})
      end

      def self.deadline(item : Api::DeadlineView, fmt : PartiduoUi::Format, today : Time) : Row
        Ui.row({
          "key"            => item.key,
          "kind"           => item.kind,
          "label"          => I18n.t(item.kind_key),
          "number"         => item.number > 0 ? item.number.to_s : nil,
          "forms"          => forms(item.forms),
          "period"         => fmt.period(item.period_from, item.period_to),
          "due_on"         => fmt.date(item.due_on),
          "overdue"        => item.overdue?(today) ? "1" : nil,
          "status"         => item.status,
          "status_label"   => item.status.try { |code| I18n.t("teledec.statuses.#{code}") },
          "status_class"   => Ui.status_class(item.status),
          "filing_url"     => item.filing_id.try { |id| Ui.url("filing", id: id) },
          "fiscal_year_id" => item.fiscal_year_id.try(&.to_s),
          "year"           => item.year.to_s,
          "vat_return_id"  => item.vat_return_id.try(&.to_s),
          "vat_missing"    => item.kind.starts_with?("vat_") && item.vat_return_id.nil? ? "1" : nil,
          "needs_amount"   => item.kind == "is_2571" ? "1" : nil,
          "locked"         => %w[transmitted acknowledged].includes?(item.status) ? "1" : nil,
        })
      end

      def self.filing(view : Api::FilingView, fmt : PartiduoUi::Format) : Row
        Ui.row({
          "id"                 => view.id.to_s,
          "label"              => I18n.t(view.kind_key),
          "kind"               => view.kind,
          "number"             => view.number > 0 ? view.number.to_s : nil,
          "forms"              => forms(view.forms),
          "period"             => fmt.period(view.period_from, view.period_to),
          "due_on"             => view.due_on.try { |day| fmt.date(day) },
          "status"             => view.status,
          "status_label"       => I18n.t(view.status_key),
          "status_class"       => Ui.status_class(view.status),
          "ready"              => view.ready? ? "1" : nil,
          "errors"             => view.errors.size.to_s,
          "blocking"           => I18n.t("teledec_ui.filings.blocking", count: view.errors.size),
          "warnings"           => view.warnings.size.to_s,
          "company"            => view.company_name,
          "siren"              => view.siren,
          "fingerprint"        => view.fingerprint,
          "remote_id"          => view.remote_id.presence,
          "remote_status"      => view.remote_status.presence.try { |code| I18n.t("teledec.remote_statuses.#{Api::REMOTE_STATUSES.includes?(code) ? code : "other"}") },
          "remote_status_code" => view.remote_status.presence,
          "remote_url"         => view.remote_url.presence.try { |url| url.starts_with?("https://") ? url : nil },
          # Dépôt transmis que le suivi de TELEDEC ne trouve pas encore
          # (DAS2, liasse : 404 juste après le dépôt) ou que la liste dit
          # seulement créé (`Created`) : à finaliser depuis son lien, relu
          # plus tard par le suivi.
          "awaiting"       => view.status == "transmitted" && Api::AWAITING_STATUSES.includes?(view.remote_status) ? "1" : nil,
          "manual"         => view.manual ? "1" : nil,
          "reason"         => view.rejection_reason.presence,
          "last_error"     => view.last_error.presence.try { |key| I18n.t(key, {"reason" => ""}) },
          "receipt"        => view.receipt_attachment_id ? "1" : nil,
          "document"       => view.document_attachment_id ? "1" : nil,
          "greffe"         => view.kind == "greffe" ? "1" : nil,
          "prepared_at"    => fmt.datetime(view.prepared_at),
          "transmitted_at" => view.transmitted_at.try { |time| fmt.datetime(time) },
          "acknowledged"   => view.acknowledged_at.try { |time| fmt.datetime(time) },
          "rejected_at"    => view.rejected_at.try { |time| fmt.datetime(time) },
          "url"            => Ui.url("filing", id: view.id),
          "prepared"       => view.status == "prepared" ? "1" : nil,
          "transmitted"    => view.status == "transmitted" ? "1" : nil,
          "rejected"       => view.status == "rejected" ? "1" : nil,
          "total_debit"    => view.balance.empty? ? nil : fmt.amount(view.total_debit),
          "total_credit"   => view.balance.empty? ? nil : fmt.amount(view.total_credit),
          "previous_rows"  => view.previous_balance_rows > 0 ? view.previous_balance_rows.to_s : nil,
        })
      end

      # Ligne de la liste des dépôts (vue résumée, sans le document).
      def self.filing_summary(view : Api::FilingSummaryView, fmt : PartiduoUi::Format) : Row
        Ui.row({
          "id"           => view.id.to_s,
          "label"        => I18n.t(view.kind_key),
          "kind"         => view.kind,
          "number"       => view.number > 0 ? view.number.to_s : nil,
          "period"       => fmt.period(view.period_from, view.period_to),
          "status"       => view.status,
          "status_label" => I18n.t(view.status_key),
          "status_class" => Ui.status_class(view.status),
          "ready"        => view.ready? ? "1" : nil,
          "blocking"     => I18n.t("teledec_ui.filings.blocking", count: view.errors.size),
          "url"          => Ui.url("filing", id: view.id),
        })
      end

      def self.balance_row(row : Api::BalanceRowView, fmt : PartiduoUi::Format) : Row
        Ui.row({"account" => row.account, "label" => row.label, "debit" => fmt.amount(row.debit),
                "credit" => fmt.amount(row.credit), "balance_debit" => row.balance_debit.zero? ? "" : fmt.amount(row.balance_debit),
                "balance_credit" => row.balance_credit.zero? ? "" : fmt.amount(row.balance_credit)})
      end

      def self.box(box : Api::BoxView, fmt : PartiduoUi::Format) : Row
        Ui.row({"form" => box.form, "box" => box.box, "amount" => fmt.amount(box.amount, 0)})
      end

      def self.das2(line : Api::Das2LineView, fmt : PartiduoUi::Format) : Row
        natures = line.amounts.map { |nature, amount| "#{I18n.t("teledec.das2_natures.#{nature}")} : #{fmt.amount(amount, 0)}" }
        person = if line.person
                   identity = "#{line.last_name} #{line.first_names}".strip
                   born = line.birth_date.try { |day| I18n.t("teledec_ui.filing.born", {"date" => fmt.date(day)}) }
                   I18n.t("teledec_ui.filing.person", {"identity" => [identity, born].compact.join(", ")})
                 end
        Ui.row({"code" => line.card_code, "name" => line.name, "siret" => line.siret.presence, "address" => line.address,
                "natures" => natures.join(" ; "), "total" => fmt.amount(line.total, 0), "person" => person})
      end

      def self.detail(key : String, value : String, fmt : PartiduoUi::Format) : Row?
        label = case key
                when "amount", "tax", "advances", "balance", "threshold"
                  value = fmt.amount(BigDecimal.new(value), 0)
                  I18n.t("teledec_ui.details.#{key}")
                when "confidential"
                  value = I18n.t(value == "1" ? "teledec_ui.answer_yes" : "teledec_ui.answer_no")
                  I18n.t("teledec_ui.details.confidential")
                when "tax_return_fingerprint" then I18n.t("teledec_ui.details.tax_return_fingerprint")
                when "source"
                  value = I18n.t("teledec_ui.details.source_#{value}")
                  I18n.t("teledec_ui.details.source")
                when "closing_neutralised"
                  value = I18n.t("teledec_ui.answer_yes")
                  I18n.t("teledec_ui.details.closing_neutralised")
                end
        label.try { |text| Ui.row({"label" => text, "value" => value}) }
      end

      def self.event(event : Api::EventView, fmt : PartiduoUi::Format) : Row
        detail = event.detail
        detail = I18n.t(detail, {"reason" => ""}) if detail.starts_with?("teledec.")
        Ui.row({"status" => I18n.t("teledec.statuses.#{event.status}"), "detail" => detail.presence,
                "at" => fmt.datetime(event.at), "status_class" => Ui.status_class(event.status)})
      end
    end
  end
end
