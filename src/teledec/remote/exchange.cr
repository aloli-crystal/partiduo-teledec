# SPDX-License-Identifier: AGPL-3.0-or-later

require "http/client"
require "uri"

module Teledec
  module Remote
    # Requête HTTP adressée à TELEDEC : verbe, adresse complète, en-têtes,
    # corps (texte).
    record Request, method : String, url : String, headers : HTTP::Headers, body : String = "" do
      def uri : URI
        URI.parse(url)
      end

      def path : String
        uri.path
      end

      def query_params : URI::Params
        URI::Params.parse(uri.query || "")
      end
    end

    # Réponse de TELEDEC : code HTTP, corps (texte), type de contenu.
    record Response, status : Int32, body : String, content_type : String = "" do
      def ok? : Bool
        200 <= status < 300
      end
    end

    # Échange HTTP avec TELEDEC. `Net` passe par le réseau ; les specs
    # branchent un TELEDEC simulé qui reçoit les mêmes requêtes
    # (`Teledec::SimulatedTeledec::Server`).
    abstract class Exchange
      abstract def call(request : Request) : Response
    end

    # Échange réel, par `HTTP::Client` : délais bornés (connexion 10 s,
    # lecture 60 s) ; une panne réseau devient
    # `teledec.errors.transport.unreachable`. Rien n'est journalisé (les
    # en-têtes portent le jeton ou les identifiants). Pas de mandataire
    # sortant (`HTTPS_PROXY`) : l'instance joint TELEDEC directement
    # (BLOCAGES B-TDC-004).
    class Net < Exchange
      CONNECT_TIMEOUT = 10.seconds
      READ_TIMEOUT    = 60.seconds

      def call(request : Request) : Response
        uri = request.uri
        client = HTTP::Client.new(uri)
        client.connect_timeout = CONNECT_TIMEOUT
        client.read_timeout = READ_TIMEOUT
        begin
          response = client.exec(request.method, uri.request_target, headers: request.headers,
            body: request.body.empty? ? nil : request.body)
          Response.new(response.status_code, response.body, response.content_type.to_s)
        ensure
          client.close
        end
      rescue ex : IO::Error | Socket::Error | OpenSSL::Error
        raise TransportError.new("teledec.errors.transport.unreachable", message: "TELEDEC injoignable : #{ex.class}")
      end
    end
  end
end
