# SPDX-License-Identifier: AGPL-3.0-or-later

module Teledec
  module Ui
    # `/ext/TELEDEC/` : écran « Télédéclarations » d'un exercice — échéances
    # (déclaration, période, date limite, statut), préparation, dépôts de
    # l'exercice, export de la balance en repli.
    class IndexHandler < Handler
      def get
        actor = current.actor
        years = Partiduo::Api::Core.fiscal_years(actor).select(&.starts_on)
        selected = pick(years)
        today = Time.utc(Time.local.year, Time.local.month, Time.local.day)
        deadlines = selected ? Api.schedule(actor, selected.id) : [] of Api::DeadlineView
        filings = selected ? Api.filings(actor, selected.id) : [] of Api::FilingView
        settings = Api.settings(actor)
        page("teledec/index.html", {
          "title"        => I18n.t("teledec_ui.title"),
          "crumbs"       => crumbs,
          "years"        => years.map { |year| Ui.row({"id" => year.id.to_s, "label" => year.label, "selected" => year.id == selected.try(&.id) ? "1" : nil}) },
          "fiscal_year"  => selected.try { |year| Ui.row({"id" => year.id.to_s, "label" => year.label, "balance_url" => Ui.url("balance", fiscal_year_id: year.id)}) },
          "deadlines"    => listed(deadlines.map { |item| Present.deadline(item, fmt, today) }),
          "filings"      => listed(filings.map { |item| Present.filing(item, fmt) }),
          "transport"    => settings.transport,
          "tax_system"   => settings.tax_system.presence.try { |code| I18n.t("teledec.tax_systems.#{code}") },
          "vat_system"   => settings.vat_system.presence.try { |code| I18n.t("teledec.vat_systems.#{code}") },
          "can_prepare"  => can?(Api::PREPARE) ? "1" : nil,
          "can_transmit" => can?(Api::TRANSMIT) ? "1" : nil,
          "can_settings" => can?(Api::SETTINGS) ? "1" : nil,
          "settings_url" => Ui.url("settings"),
          "prepare_url"  => Ui.url("prepare"),
          "refresh_url"  => Ui.url("refresh_all"),
          "unconfigured" => settings.tax_system.empty? ? "1" : nil,
        })
      end

      # Exercice choisi (`fy`), sinon le plus récent déjà clos à la date du
      # jour, sinon le plus récent.
      private def pick(years : Array(Partiduo::Api::Core::FiscalYearView)) : Partiduo::Api::Core::FiscalYearView?
        wanted = query("fy").to_i64?
        found = wanted.try { |id| years.find(&.id.==(id)) }
        return found if found
        today = Time.utc
        years.find { |year| (ends_on = year.ends_on) && ends_on < today } || years.first?
      end
    end

    # Préparation d'une déclaration depuis une échéance.
    class PrepareHandler < Handler
      def get
        go(Ui.url("index"))
      end

      def post
        amount = field("amount").presence.try { |text| fmt.parse_decimal(text) }
        input = Api::PrepareInput.new(kind: field("kind"), fiscal_year_id: field("fiscal_year_id").to_i64?,
          year: field("year").to_i?, number: field("number").to_i? || 0, vat_return_id: field("vat_return_id").to_i64?,
          amount: amount, confidential: field("confidential") == "1")
        result = Api.prepare(current.actor, input)
        if view = result.value?
          flash["success"] = I18n.t("teledec_ui.flash.prepared")
          return go(Ui.url("filing", id: view.id))
        end
        flash["danger"] = messages(result)
        fy = field("fiscal_year_id")
        go(fy.empty? ? Ui.url("index") : "#{Ui.url("index")}?fy=#{fy}")
      end
    end

    # Interroge TELEDEC sur tous les dépôts transmis.
    class RefreshAllHandler < Handler
      def get
        go(Ui.url("index"))
      end

      def post
        count = Api.refresh_all(current.actor)
        flash["success"] = I18n.t("teledec_ui.flash.refreshed_all", count: count)
        go(Ui.url("index"))
      end
    end

    # Balance de l'exercice au format d'import (repli).
    class BalanceHandler < Handler
      def get
        file_response(Api.balance_file(current.actor, id_param("fiscal_year_id")))
      end
    end
  end
end
