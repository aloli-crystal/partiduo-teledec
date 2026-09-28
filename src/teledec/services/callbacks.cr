# SPDX-License-Identifier: AGPL-3.0-or-later

require "crypto/subtle"

module Teledec
  # Rappels de TELEDEC (webhook) : à chaque étape d'une déclaration
  # (envoi, accusé ou rejet de la DGFiP), TELEDEC poste un JSON
  # (`declarationId`, `reference`, `status`, `formulairesStatus`,
  # `declarationErreurs`, `pdf` de l'accusé…) à l'adresse donnée dans
  # `auth.url` de la marque blanche, ou à celle configurée chez TELEDEC
  # (protégée par HTTP Basic ou jeton permanent).
  #
  # Le rappel est authentifié par le jeton des rappels de l'instance
  # (aléatoire, chiffré dans les paramètres), présenté en mot de passe
  # `Basic` (à préférer : configuré chez TELEDEC), en `Bearer` ou en
  # paramètre `token` (adresse `auth.url`, en https seulement) ; il est
  # rattaché au dépôt par la référence envoyée (sinon, sans référence, par
  # l'identifiant de la déclaration), les rappels de paiement sont
  # ignorés, et il est idempotent : un rappel rejoué pour une déclaration
  # déjà accusée ou rejetée ne change rien. Interne : appelé par
  # `Api.callback`.
  module Callbacks
    alias Api = Teledec::Api

    # Route exposée par l'interface, hors de `/ext/` (pas de session).
    PATH = "/hooks/TELEDEC/callback"

    # Taille maximale d'un rappel (accusé en base64 compris). L'interface
    # refuse en 413 un `Content-Length` plus grand avant de lire le corps ;
    # Marten borne de toute façon la lecture (`request_max_body_size`,
    # 2,5 Mo par défaut).
    MAX_BYTES = 8 * 1024 * 1024

    def self.new_token : String
      Random::Secure.urlsafe_base64(32)
    end

    def self.active? : Bool
      Partiduo::Api::Modules.get(Partiduo::Api::Actor.system, CODE).active
    rescue Partiduo::Api::NotFound
      false
    end

    # Jeton des rappels, `nil` s'il n'y en a pas (ou illisible).
    def self.token(settings : Settings = Settings.current!) : String?
      Secrets.decrypt(settings.callback_token.to_s).presence
    rescue Secrets::Error
      nil
    end

    # Chemin des rappels, jeton compris ; `nil` sans jeton.
    def self.path(settings : Settings = Settings.current!) : String?
      token(settings).try { |value| "#{PATH}?#{URI::Params.encode({"token" => value})}" }
    end

    # Adresse publique de l'instance (`https://<hôte>`), tirée de ses
    # réglages et jamais de la requête (en-tête `Host`, schéma derrière un
    # mandataire) : domaine de la société (`provision --domain`), sinon
    # `PARTIDUO_HOST`, sinon le premier de `MARTEN_ALLOWED_HOSTS` ; `nil` si
    # aucun n'est un nom d'hôte (DECISIONS D-TDC-027).
    def self.instance_base_url : String?
      domain = begin
        Partiduo::Api::Core.settings(Partiduo::Api::Actor.system).domain
      rescue Partiduo::Api::NotFound
        ""
      end
      candidates = [domain, ENV["PARTIDUO_HOST"]?, ENV["MARTEN_ALLOWED_HOSTS"]?.try(&.split(',').first?)]
      host = candidates.compact.map(&.strip.downcase).find(&.matches?(HOST)) || return
      "https://#{host}"
    end

    # Nom d'hôte, port facultatif ; ni schéma, ni chemin, ni joker.
    HOST = /\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+(:\d{1,5})?\z/

    # Adresse complète des rappels, jeton compris, sous `base_url` (défaut :
    # adresse publique de l'instance) ; `https://` seulement — le jeton ne
    # circule jamais en clair —, sinon `nil` (suivi par `refresh`). `nil`
    # aussi sans jeton.
    def self.url(base_url : String? = instance_base_url) : String?
      base = base_url.try(&.rstrip('/')).presence || return
      return unless base.starts_with?("https://")
      path.try { |value| "#{base}#{value}" }
    end

    def self.authenticate(presented : String?) : Bool
      expected = token || return false
      value = presented || return false
      return false unless value.bytesize == expected.bytesize
      Crypto::Subtle.constant_time_compare(value.to_slice, expected.to_slice)
    end

    # Traite un rappel authentifié ; voir `Api.callback`.
    def self.receive(body : String) : String
      return "invalid" if body.bytesize > MAX_BYTES
      report = begin
        Remote::Formats.report(JSON.parse(body))
      rescue JSON::ParseException | TransportError
        return "invalid"
      end
      attachment = report.pdf.try do |pdf|
        name = "#{report.state == "acknowledged" ? "accuse" : "rejet"}-#{report.form.presence || "teledec"}-#{report.declaration_id.presence || "declaration"}.pdf"
        Partiduo::Api::Core::AttachmentInput.new(name.gsub(/[^A-Za-z0-9._-]/, "_"), "application/pdf", IO::Memory.new(pdf))
      end
      outcome = Partiduo::Api::Transaction.run do
        Filings.lock!
        filing = concerned(report)
        next Partiduo::Api::Result(String).success("ignored") if filing.nil?
        declaration_id = report.declaration_id[0, 64]
        final = filing.status == "acknowledged" || filing.status == "rejected"
        if final && (declaration_id.empty? || filing.declaration_id == declaration_id || filing.status == "acknowledged")
          next Partiduo::Api::Result(String).success("ok")
        end
        next Partiduo::Api::Result(String).success("ignored") unless filing.status == "transmitted"
        filing.declaration_id = declaration_id unless declaration_id.empty?
        filing.remote_status = Remote::Formats.normalize(report.status)[0, 32] unless report.status.empty?
        filing.last_error = ""
        state = report.state
        unless state == "acknowledged" || state == "rejected"
          filing.save!
          next Partiduo::Api::Result(String).success("ok")
        end
        applied = Filings.apply_outcome(filing, state, report.reason, attachment, report.at, nil)
        next Partiduo::Api::Result(String).failure(applied.errors) if applied.failure?
        Partiduo::Api::Result(String).success("ok")
      end
      outcome.success? ? outcome.value! : "invalid"
    end

    # Dépôt que le rappel concerne : ni noté à la main, ni visé par un
    # rappel de paiement ou d'un autre type de déclaration (il ne dit rien
    # de l'accusé du dépôt, D-TDC-024).
    private def self.concerned(report : Remote::Formats::Report) : Filing?
      filing = find(report) || return
      filing if !filing.manual && Remote::Formats.concerns?(report, filing.kind.to_s)
    end

    # Dépôt visé : par la référence envoyée ; par l'identifiant de la
    # déclaration seulement si le rappel ne porte pas de référence. Une
    # référence qui ne correspond à aucun dépôt est celle d'un envoi
    # précédent (rejeté puis envoyé de nouveau) : le rappel est ignoré, il
    # ne vaut pas pour l'envoi en cours (D-TDC-025).
    private def self.find(report : Remote::Formats::Report) : Filing?
      unless report.reference.empty?
        return Filing.filter(remote_reference: report.reference[0, 128]).first
      end
      return if report.declaration_id.empty?
      Filing.filter(declaration_id: report.declaration_id[0, 64]).first
    end
  end
end
