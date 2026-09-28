# SPDX-License-Identifier: AGPL-3.0-or-later

module Teledec
  module Ui
    # `/ext/TELEDEC/settings` : régime d'imposition (formulaires de la
    # liasse), régime de TVA, dépôt des comptes au greffe, comptes et seuil
    # de la DAS2, identifiants de l'API (la clé n'est jamais réaffichée).
    class SettingsHandler < Handler
      def get
        require_settings!
        show({} of String => Array(String))
      end

      def post
        require_settings!
        accounts = parse_accounts(field("das2_accounts", strip: false))
        threshold = field("das2_threshold").presence.try { |text| fmt.parse_decimal(text) }
        input = Api::SettingsInput.new(tax_system: field("tax_system"), vat_system: field("vat_system"),
          greffe: field("greffe") == "1", das2_accounts: accounts, das2_threshold: threshold)
        result = Api.update_settings(current.actor, input)
        if result.success?
          flash["success"] = I18n.t("teledec_ui.flash.settings")
          return go(Ui.url("settings"))
        end
        show(errors_of(result), 422)
      end

      def show(errors : Hash(String, Array(String)), status : Int32 = 200) : Marten::HTTP::Response
        view = Api.settings(current.actor)
        options = ->(codes : Array(String), prefix : String, selected : String) do
          codes.map { |code| Ui.row({"value" => code, "label" => I18n.t("#{prefix}.#{code}"), "selected" => code == selected ? "1" : nil}) }
        end
        page("teledec/settings.html", {
          "title"        => I18n.t("teledec_ui.settings.title"),
          "crumbs"       => [crumb("core.menu.settings"), PartiduoUi::Screen::Crumb.new(I18n.t("teledec_ui.settings.title"))],
          "tax_systems"  => options.call(Api::TAX_SYSTEMS, "teledec.tax_systems", view.tax_system),
          "vat_systems"  => options.call(Api::VAT_SYSTEMS, "teledec.vat_systems", view.vat_system),
          "environments" => options.call(Api::ENVIRONMENTS, "teledec.environments", view.env),
          "natures"      => Api::DAS2_NATURES.map { |code| "#{code} (#{I18n.t("teledec.das2_natures.#{code}")})" }.join(", "),
          "settings"     => Ui.row({
            "greffe"         => view.greffe ? "1" : nil,
            "das2_accounts"  => view.das2_accounts.map { |prefix, nature| "#{prefix}=#{nature}" }.join("\n"),
            "das2_threshold" => fmt.input_number(view.das2_threshold),
            "login"          => view.login.presence,
            "email"          => view.email.presence,
            "siret"          => view.siret.presence,
            "callback_url"   => view.callback_url.presence,
            "callback_path"  => view.callback_path.presence,
            "key_stored"     => view.key_stored ? "1" : nil,
            "checked_at"     => view.checked_at.try { |time| fmt.datetime(time) },
            "transport"      => view.transport,
            "env"            => I18n.t("teledec.environments.#{view.env}"),
            "env_code"       => view.env,
          }),
          "errors" => Ui.row(errors.transform_values { |list| list.join(" ").as(String?) }),
          "base"   => errors["base"]?.try(&.join(" ")),
        }, status: status)
      end

      # `6226=fees` par ligne ; lignes vides ignorées. Une ligne mal formée
      # est gardée telle quelle pour que le contrat la refuse.
      private def parse_accounts(text : String) : Hash(String, String)
        text.lines.map(&.strip).reject(&.empty?).to_h do |line|
          prefix, _, nature = line.partition('=')
          {prefix.strip, nature.strip}
        end
      end

      private def require_settings! : Nil
        raise Partiduo::Api::Forbidden.new(Api::SETTINGS) unless can?(Api::SETTINGS)
      end
    end

    class CredentialsHandler < SettingsHandler
      def get
        go(Ui.url("settings"))
      end

      def post
        input = Api::CredentialsInput.new(login: field("login"), api_key: field("api_key"), env: field("env"),
          email: field("email"), siret: field("siret"), renew_callback_token: field("renew_callback_token") == "1")
        result = Api.save_credentials(current.actor, input)
        if result.success?
          flash["success"] = I18n.t("teledec_ui.flash.credentials")
          return go(Ui.url("settings"))
        end
        show(errors_of(result), 422)
      end
    end

    class ClearCredentialsHandler < Handler
      def get
        go(Ui.url("settings"))
      end

      def post
        Api.clear_credentials(current.actor)
        flash["success"] = I18n.t("teledec_ui.flash.credentials_cleared")
        go(Ui.url("settings"))
      end
    end
  end
end
