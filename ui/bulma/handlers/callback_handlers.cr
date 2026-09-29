# SPDX-License-Identifier: AGPL-3.0-or-later

module Teledec
  module Ui
    # `POST /hooks/TELEDEC/callback` : rappel de TELEDEC (webhook), sans
    # session ni jeton CSRF — l'appel est authentifié par le mot de passe
    # des rappels du partenaire, en `Basic` (`Teledec::Api.callback`).
    # Réponses : 200 (rappel traité, ignoré ou rejoué), 400 (corps
    # illisible), 401 (mot de passe absent ou faux, ou non réglé dans
    # l'instance), 404 (extension inactive), 405 (autre verbe), 413
    # (`Content-Length` au-delà de `Callbacks::MAX_BYTES`, corps non lu).
    class CallbackHandler < Marten::Handler
      protect_from_forgery false

      def post
        # Corps annoncé trop gros : refusé avant d'être lu.
        if (length = request.headers["Content-Length"]?.try(&.to_i64?)) && length > Callbacks::MAX_BYTES
          return json({"status" => "too_large"}, 413)
        end
        outcome = Api.callback(request.headers["Authorization"]?, request.body)
        case outcome
        when "unauthorized"
          response = json({"status" => "unauthorized"}, 401)
          response["WWW-Authenticate"] = %(Basic realm="partiduo-teledec")
          response
        when "invalid"
          json({"status" => "invalid"}, 400)
        else
          json({"status" => "ok"}, 200)
        end
      rescue Partiduo::Api::ModuleDisabled
        json({"status" => "not_found"}, 404)
      end

      def get
        json({"status" => "method_not_allowed"}, 405)
      end

      private def json(body : Hash(String, String), status : Int32) : Marten::HTTP::Response
        Marten::HTTP::Response.new(content: body.to_json, content_type: "application/json", status: status)
      end
    end
  end
end
