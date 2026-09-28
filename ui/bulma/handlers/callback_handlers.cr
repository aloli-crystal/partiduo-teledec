# SPDX-License-Identifier: AGPL-3.0-or-later

require "base64"

module Teledec
  module Ui
    # `POST /hooks/TELEDEC/callback` : rappel de TELEDEC (webhook), sans
    # session ni jeton CSRF — l'appel est authentifié par le jeton des
    # rappels de l'instance, présenté en mot de passe `Basic`, en `Bearer`
    # ou en paramètre `token` (`Teledec::Api.callback`). Réponses : 200 (rappel
    # traité, ignoré ou rejoué), 400 (corps illisible), 401 (jeton absent
    # ou faux), 404 (extension inactive), 405 (autre verbe).
    class CallbackHandler < Marten::Handler
      protect_from_forgery false

      def post
        outcome = Api.callback(presented_token, request.body)
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

      private def presented_token : String?
        header = request.headers["Authorization"]?.to_s.strip
        if header.starts_with?("Bearer ")
          return header.lchop("Bearer ").strip.presence
        elsif header.starts_with?("Basic ")
          decoded = begin
            String.new(Base64.decode(header.lchop("Basic ").strip))
          rescue Base64::Error
            ""
          end
          return decoded.partition(':')[2].presence
        end
        request.query_params["token"]?.presence
      end

      private def json(body : Hash(String, String), status : Int32) : Marten::HTTP::Response
        Marten::HTTP::Response.new(content: body.to_json, content_type: "application/json", status: status)
      end
    end
  end
end
