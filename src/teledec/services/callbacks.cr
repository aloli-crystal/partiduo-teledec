# SPDX-License-Identifier: AGPL-3.0-or-later

require "base64"
require "crypto/subtle"

module Teledec
  # Rappels de TELEDEC (webhook) : à l'envoi, à l'acceptation et au rejet
  # par la DGFiP *seulement* — aucun au simple dépôt (réponses de TELEDEC
  # du 1er octobre 2026, D-TDC9-004) —, TELEDEC poste un JSON
  # (`declarationId`, `reference`, `status`, `declarationStatus`,
  # `declarationErreurs`, `pdf` de l'accusé, `lienPdf`…) à l'adresse
  # donnée dans chaque dépôt : `auth.url` en marque blanche et pour le
  # greffe, `#URL` dans la liasse (API Balance, qui écrit aussi au compte
  # de l'entreprise). Un rappel d'un dépôt au greffe finalisé qui porte
  # `lienPdf` fait relever et conserver son PDF signé (D-TDC9-002) ; s'il ne
  # peut être relevé, le dépôt reste transmis, l'erreur notée, et le suivi
  # (`refresh`) reprend.
  #
  # Authentification (réponses de TELEDEC du 29 septembre 2026,
  # D-TDC3-006) : HTTP `Basic`, avec *un* mot de passe par partenaire,
  # configuré chez TELEDEC et dans l'instance
  # (`PARTIDUO_TELEDEC_CALLBACK_PASSWORD`, jamais journalisé ni affiché ;
  # identifiant facultatif `PARTIDUO_TELEDEC_CALLBACK_USER`). Sans mot de
  # passe réglé, tout rappel est refusé et le suivi se fait par `refresh`.
  # Le rappel est rattaché au dépôt par la référence envoyée (sinon, sans
  # référence, par l'identifiant de la déclaration), ceux d'un autre type
  # de déclaration sont ignorés, et il est idempotent : un rappel rejoué
  # pour une déclaration déjà accusée ou rejetée ne change rien. Interne :
  # appelé par `Api.callback`.
  module Callbacks
    alias Api = Teledec::Api

    # Route exposée par l'interface, hors de `/ext/` (pas de session).
    PATH = "/hooks/TELEDEC/callback"

    # Taille maximale d'un rappel (accusé en base64 compris). L'interface
    # refuse en 413 un `Content-Length` plus grand avant de lire le corps ;
    # Marten borne de toute façon la lecture (`request_max_body_size`,
    # 2,5 Mo par défaut).
    MAX_BYTES = 8 * 1024 * 1024

    PASSWORD_VARIABLE = "PARTIDUO_TELEDEC_CALLBACK_PASSWORD"
    USER_VARIABLE     = "PARTIDUO_TELEDEC_CALLBACK_USER"

    def self.active? : Bool
      Partiduo::Api::Modules.get(Partiduo::Api::Actor.system, CODE).active
    rescue Partiduo::Api::NotFound
      false
    end

    # Mot de passe des rappels du partenaire (réglage de l'instance), `nil`
    # s'il n'est pas réglé.
    def self.password : String?
      ENV[PASSWORD_VARIABLE]?.presence
    end

    def self.configured? : Bool
      !password.nil?
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

    # Adresse des rappels sous `base_url` (défaut : adresse publique de
    # l'instance), donnée à TELEDEC dans chaque dépôt ; `https://`
    # seulement (le mot de passe `Basic` ne circule jamais en clair), et
    # seulement si le mot de passe des rappels est réglé, sinon `nil`
    # (suivi par `refresh`).
    def self.url(base_url : String? = instance_base_url) : String?
      return unless configured?
      base = base_url.try(&.rstrip('/')).presence || return
      return unless base.starts_with?("https://")
      "#{base}#{PATH}"
    end

    # Vérifie l'en-tête `Authorization` (`Basic`) : mot de passe du
    # partenaire (et identifiant s'il est réglé), comparés en temps
    # constant.
    def self.authenticate(authorization : String?) : Bool
      expected = password || return false
      header = authorization.to_s.strip
      return false unless header.starts_with?("Basic ")
      decoded = begin
        String.new(Base64.decode(header.lchop("Basic ").strip))
      rescue Base64::Error
        return false
      end
      user, _, presented = decoded.partition(':')
      if wanted_user = ENV[USER_VARIABLE]?.presence
        return false unless same?(user, wanted_user)
      end
      same?(presented, expected)
    end

    private def self.same?(value : String, expected : String) : Bool
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
      document, document_failed = greffe_document(report)
      outcome = Partiduo::Api::Transaction.run do
        Filings.lock!
        filing = concerned(report)
        next Partiduo::Api::Result(String).success("ignored") if filing.nil?
        apply(filing, report, attachment, document, document_failed)
      end
      outcome.success? ? outcome.value! : "invalid"
    end

    alias Outcome = Partiduo::Api::Result(String)

    # Applique le rappel au dépôt relu sous le verrou.
    private def self.apply(filing : Filing, report : Remote::Formats::Report,
                           attachment : Partiduo::Api::Core::AttachmentInput?, document : Receipt?,
                           document_failed : Bool) : Outcome
      declaration_id = report.declaration_id[0, 64]
      final = filing.status == "acknowledged" || filing.status == "rejected"
      if final && (declaration_id.empty? || filing.declaration_id == declaration_id || filing.status == "acknowledged")
        return replayed(filing, document)
      end
      return Outcome.success("ignored") unless filing.status == "transmitted"
      filing.declaration_id = declaration_id unless declaration_id.empty?
      filing.remote_status = Remote::Formats.normalize(report.status)[0, 32] unless report.status.empty?
      filing.last_error = ""
      if document
        refused = Filings.store_document(filing, document, nil)
        return Outcome.failure(refused) unless refused.empty?
      end
      state = report.state
      # PDF du greffe non relevé : le dépôt reste transmis, le suivi
      # reprendra l'accusé et le PDF ensemble.
      filing.last_error = DOCUMENT_ERROR if document_failed
      if document_failed || !(state == "acknowledged" || state == "rejected")
        filing.save!
        return Outcome.success("ok")
      end
      applied = Filings.apply_outcome(filing, state, report.reason, attachment, report.at, nil)
      applied.failure? ? Outcome.failure(applied.errors) : Outcome.success("ok")
    end

    # Rappel rejoué pour un dépôt déjà accusé ou rejeté : rien ne change,
    # sauf un PDF du greffe encore absent, repris.
    private def self.replayed(filing : Filing, document : Receipt?) : Outcome
      if document && filing.document_attachment_id.nil?
        refused = Filings.store_document(filing, document, nil)
        return Outcome.failure(refused) unless refused.empty?
        filing.save!
      end
      Outcome.success("ok")
    end

    DOCUMENT_ERROR = "teledec.errors.transport.document"

    # PDF signé d'un dépôt au greffe finalisé que le rappel désigne
    # (`lienPdf`), relevé chez TELEDEC hors transaction ; rend aussi vrai si
    # le relevé a échoué (transport absent, identifiants illisibles, refus
    # ou panne de TELEDEC). Rien pour un autre dépôt, un dépôt dont le PDF
    # est déjà conservé, ou un rappel sans lien.
    private def self.greffe_document(report : Remote::Formats::Report) : {Receipt?, Bool}
      token = Remote::Formats.pdf_token(report.pdf_link)
      return {nil, false} unless token && Remote::Formats.finalized?(report.status)
      filing = concerned(report)
      return {nil, false} unless filing && filing.kind == "greffe" && filing.document_attachment_id.nil?
      key = Remote::Formats::Key.parse(filing.remote_id.to_s) || return {nil, false}
      transport = Transports.current || return {nil, true}
      found = Filings.credentials(Settings.current!)
      return {nil, true} if found.failure?
      {transport.document(found.value!, token, HttpTransport.document_name(key)), false}
    rescue ex : TransportError
      Log.warn { "TELEDEC : PDF du dépôt au greffe non relevé (#{ex.key})" }
      {nil, true}
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
