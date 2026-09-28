# SPDX-License-Identifier: AGPL-3.0-or-later

module Teledec
  module Ui
    # Base des écrans de l'extension. L'accès a déjà été contrôlé par
    # `PartiduoUi::ExtensionHandler` à partir du manifeste ; `Teledec::Api`
    # vérifie encore la permission de chaque commande.
    abstract class Handler < PartiduoUi::ScreenHandler
      alias Api = Teledec::Api

      def messages(result) : String
        result.errors.map { |error| fmt.message(error) }.join(" ")
      end

      def crumbs(title : String? = nil) : Array(PartiduoUi::Screen::Crumb)
        list = [crumb("core.menu.vat"), crumb("teledec.menu.returns", title ? Ui.url("index") : nil)]
        list << PartiduoUi::Screen::Crumb.new(title) if title
        list
      end

      def file_response(file : Api::FileView) : Marten::HTTP::Response
        response = Marten::HTTP::Response.new(content: String.new(file.content), content_type: file.content_type)
        response["Content-Disposition"] = %(attachment; filename="#{file.filename}")
        response
      end

      # Redirection vers la fiche d'un dépôt après une commande, avec le
      # message du résultat.
      def after(result, id : Int64, success_key : String) : Marten::HTTP::Response
        if result.success?
          flash["success"] = I18n.t(success_key)
        else
          flash["danger"] = messages(result)
        end
        go(Ui.url("filing", id: id))
      end
    end
  end
end
