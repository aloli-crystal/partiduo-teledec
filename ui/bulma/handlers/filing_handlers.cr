# SPDX-License-Identifier: AGPL-3.0-or-later

module Teledec
  module Ui
    # `/ext/TELEDEC/filings/<id>` : un dépôt — statut, contrôles, contenu
    # (balance, cases, bénéficiaires de la DAS2), historique ; contrôler,
    # transmettre, actualiser, noter un dépôt fait hors de Partiduo.
    class FilingHandler < Handler
      def get
        actor = current.actor
        view = Api.filing(actor, id_param)
        filing = Present.filing(view, fmt)
        details = view.details.compact_map { |key, value| Present.detail(key, value, fmt) }
        page("teledec/filing.html", {
          "title"         => "#{I18n.t(view.kind_key)} — #{fmt.period(view.period_from, view.period_to)}",
          "crumbs"        => crumbs(I18n.t(view.kind_key)),
          "filing"        => filing,
          "errors"        => listed(view.errors.map { |item| Present.control(item, fmt) }),
          "warnings"      => listed(view.warnings.map { |item| Present.control(item, fmt) }),
          "balance"       => listed(view.balance.map { |row| Present.balance_row(row, fmt) }),
          "boxes"         => listed(view.boxes.map { |box| Present.box(box, fmt) }),
          "das2"          => listed(view.das2.map { |line| Present.das2(line, fmt) }),
          "details"       => listed(details),
          "events"        => listed(Api.events(actor, view.id).reverse.map { |event| Present.event(event, fmt) }),
          "transport"     => Api.transport_name(actor),
          "can_prepare"   => can?(Api::PREPARE) ? "1" : nil,
          "can_transmit"  => can?(Api::TRANSMIT) ? "1" : nil,
          "check_url"     => Ui.url("check", id: view.id),
          "transmit_url"  => Ui.url("transmit", id: view.id),
          "refresh_url"   => Ui.url("refresh", id: view.id),
          "outcome_url"   => Ui.url("outcome", id: view.id),
          "export_url"    => Ui.url("export", id: view.id),
          "receipt_url"   => Ui.url("receipt", id: view.id),
          "prepare_url"   => Ui.url("prepare"),
          "balance_url"   => view.fiscal_year_id.try { |id| view.balance.empty? ? nil : Ui.url("balance", fiscal_year_id: id) },
          "back_url"      => view.fiscal_year_id.try { |id| "#{Ui.url("index")}?fy=#{id}" } || Ui.url("index"),
          "prepare_again" => Ui.row({"kind" => view.kind, "fiscal_year_id" => view.fiscal_year_id.try(&.to_s),
                                     "year" => view.year.to_s, "number" => view.number.to_s,
                                     "vat_return_id" => view.vat_return_id.try(&.to_s),
                                     "amount" => view.details["amount"]? || view.details["tax"]?,
                                     "confidential" => view.details["confidential"]?}),
        })
      end
    end

    class CheckHandler < Handler
      def get
        go(Ui.url("filing", id: id_param))
      end

      def post
        after(Api.check(current.actor, id_param), id_param, "teledec_ui.flash.checked")
      end
    end

    class TransmitHandler < Handler
      def get
        go(Ui.url("filing", id: id_param))
      end

      def post
        after(Api.transmit(current.actor, id_param, base_url), id_param, "teledec_ui.flash.transmitted")
      end

      # Adresse publique de l'instance, pour les rappels de TELEDEC.
      private def base_url : String
        port = request.port.presence
        default = port.nil? || (request.scheme == "https" && port == "443") || (request.scheme == "http" && port == "80")
        "#{request.scheme}://#{request.host}#{default ? "" : ":#{port}"}"
      end
    end

    class RefreshHandler < Handler
      def get
        go(Ui.url("filing", id: id_param))
      end

      def post
        after(Api.refresh(current.actor, id_param), id_param, "teledec_ui.flash.refreshed")
      end
    end

    # Issue d'un dépôt fait hors de Partiduo : transmis, accusé (avec le
    # fichier de l'accusé) ou rejeté (motif).
    class OutcomeHandler < Handler
      TYPES = {"pdf" => "application/pdf", "xml" => "application/xml", "png" => "image/png",
               "jpg" => "image/jpeg", "jpeg" => "image/jpeg", "txt" => "text/plain"}

      def get
        go(Ui.url("filing", id: id_param))
      end

      def post
        file = request.data["receipt"]?
        input = if file.is_a?(Marten::HTTP::UploadedFile) && file.size > 0
                  name = file.filename.to_s
                  type = TYPES[File.extname(name).lchop('.').downcase]? || "application/octet-stream"
                  Api::OutcomeInput.new(status: field("status"), reason: field("reason"), reference: field("reference"),
                    receipt_filename: name, receipt_content_type: type, receipt: file.io)
                else
                  Api::OutcomeInput.new(status: field("status"), reason: field("reason"), reference: field("reference"))
                end
        after(Api.record_outcome(current.actor, id_param, input), id_param, "teledec_ui.flash.outcome")
      end
    end

    class ExportHandler < Handler
      def get
        file_response(Api.export_file(current.actor, id_param))
      end
    end

    class ReceiptHandler < Handler
      def get
        file = Api.receipt_file(current.actor, id_param)
        return PartiduoUi::ErrorPage.render(request, 404) unless file
        file_response(file)
      end
    end
  end
end
