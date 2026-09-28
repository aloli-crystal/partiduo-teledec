# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"
require "base64"

module Teledec
  module Remote
    # Traduction du document neutre (`Teledec::Payload`) dans les formats de
    # l'API partenaire de TELEDEC, et lecture de ses réponses. Sources :
    # synthèse de l'API relevée sur le portail partenaires et spécifications
    # JSON des formulaires (codes par millésime) ; ce qui reste incertain est
    # consigné dans BLOCAGES (B-TDC-004).
    #
    # * Liasse : API Balance (`POST /service/liasse`), texte en trois
    #   sections — identification `#CLE valeur`, balance
    #   `compte;libellé;ouv. débit;ouv. crédit;mvt débit;mvt crédit;solde
    #   débit;solde crédit`, bloc JSON facultatif (`zones_formulaires`).
    # * TVA, DAS2, IS : API marque blanche
    #   (`POST /service/declaration-marque-blanche`), JSON `auth`,
    #   `identity`, `period` et un bloc par formulaire en clés/valeurs.
    module Formats
      # Formulaire principal de chaque sorte, tel que TELEDEC le nomme
      # (bloc de la marque blanche, paramètre `formulaire` du suivi).
      FORM_KEYS = {
        "liasse"   => "liasse",
        "vat_ca3"  => "3310CA3",
        "vat_ca12" => "3517SCA12",
        "das2"     => "DAS2",
        "is_2571"  => "2571",
        "is_2572"  => "2572",
      }

      # Cases de la CA3 de Partiduo (lignes du 3310-CA3) → codes TELEDEC du
      # formulaire `3310CA3`, par premier millésime d'application. La
      # ligne 14 (taux particuliers) se détaille sur l'annexe 3310-A, que
      # Partiduo ne tient pas (D-TVA-006) : non transmissible.
      CA3_CODES = {
        2024 => {
          "A1" => "CA", "A2" => "CB", "A3" => "KH", "A4" => "KW", "A5" => "KX", "B2" => "KZ", "B4" => "CG",
          "B5" => "CE", "E1" => "DA", "E2" => "DB", "F2" => "DC", "F6" => "DD",
          "08.base" => "FP", "08.tax" => "GP", "09.base" => "FB", "09.tax" => "GB", "9B.base" => "FR", "9B.tax" => "GR",
          "10.base" => "FM", "10.tax" => "GM", "11.base" => "FN", "11.tax" => "GN", "13.base" => "FC", "13.tax" => "GC",
          "15" => "GG", "16" => "GH", "17" => "GJ", "19" => "HA", "20" => "HB", "21" => "HC", "22" => "HD",
          "23" => "HG", "25" => "JA", "26" => "JB", "27" => "JC", "28" => "KA", "29" => "KB", "32" => "KE",
        },
      }

      # Cases de la CA12 de Partiduo → codes TELEDEC du formulaire
      # `3517SCA12`. La ligne A1 (total des ventes) n'a pas de code : la
      # CA12 ne porte que les bases par taux ; A2, A4, A5, B2, B5, 17, 29 et
      # la ligne 14 n'ont pas d'équivalent sûr : non transmissibles.
      CA12_CODES = {
        2024 => {
          "08.base" => "EW", "08.tax" => "FW", "09.base" => "EF", "09.tax" => "FF", "9B.base" => "GF", "9B.tax" => "GH",
          "10.base" => "EU", "10.tax" => "FU", "11.base" => "EV", "11.tax" => "FV", "13.base" => "EG", "13.tax" => "FG",
          "A3" => "EH", "B4" => "VN", "E1" => "EB", "E2" => "EC", "F2" => "ED", "F6" => "EA",
          "15" => "GB", "16" => "GC", "19" => "JA", "20" => "HA", "21" => "KB", "22" => "KA", "23" => "KD",
          "25" => "LB", "28" => "LA", "ac" => "MM", "sp" => "NA", "ex" => "NB",
        },
      }

      # Cases sans code qui ne sont que des totaux repris ailleurs.
      IGNORED = {"3517SCA12" => %w[A1]}

      # Natures de la DAS2 → lettre de la DGFiP (cases 4 et 5).
      DAS2_LETTERS = {
        "fees" => "H", "commissions" => "C", "brokerage" => "O", "rebates" => "R", "attendance" => "J",
        "copyright" => "A", "inventor" => "I", "other" => "V",
      }

      # Formes juridiques de Partiduo (texte libre des paramètres de la
      # société) → codes de TELEDEC ; inconnue : `ZZZ` (autre).
      LEGAL_FORMS = {
        "ASSOCIATION" => "ASS", "EARL" => "ARL", "EI" => "EI", "EIRL" => "EIR", "EURL" => "ERL", "GAEC" => "GEC",
        "GIE" => "GIE", "INDIVISION" => "IND", "LMNP" => "LMNP", "SA" => "SA", "SAS" => "SAS", "SASU" => "SASU",
        "SARL" => "SRL", "SCEA" => "SEA", "SCI" => "SCI", "SCM" => "SCM", "SELARL" => "SLR", "SCS" => "SCS",
        "SNC" => "SNC",
      }

      # Catégorie fiscale et régime de la liasse, d'après ses formulaires.
      CATEGORIES = {
        %w[2065 2033] => {"BIC-IS", "SIMPLIFIE"},
        %w[2065 2050] => {"BIC-IS", "NORMAL"},
        %w[2031 2033] => {"BIC-IR", "SIMPLIFIE"},
        %w[2031 2050] => {"BIC-IR", "NORMAL"},
        %w[2035]      => {"BNC", nil},
        %w[2072]      => {"SCI2072", nil},
      }

      def self.form_key(kind : String) : String?
        FORM_KEYS[kind]?
      end

      # Table des codes d'un formulaire de TVA pour un millésime : la plus
      # récente applicable.
      def self.codes(form : String, millesime : Int32) : Hash(String, String)
        tables = form == "3517SCA12" ? CA12_CODES : CA3_CODES
        year = tables.keys.select(&.<=(millesime)).max? || tables.keys.min
        tables[year]
      end

      # Cases non nulles de TVA qu'aucun code TELEDEC ne reçoit (contrôle
      # bloquant à la préparation).
      def self.unmapped(kind : String, boxes : Hash(String, String), millesime : Int32) : Array(String)
        form = form_key(kind) || return [] of String
        return [] of String unless kind.starts_with?("vat_")
        table = codes(form, millesime)
        ignored = IGNORED[form]? || [] of String
        boxes.compact_map do |box, amount|
          next if Money.parse(amount).zero? || ignored.includes?(box)
          box unless table.has_key?(box)
        end
      end

      # --- Identifiant de suivi --------------------------------------------------

      # Identifiant d'un dépôt chez TELEDEC, tel que le suivi l'interroge :
      # `<formulaire>:<siren>:<date de fin>[:<échéance>]`. TELEDEC ne rend pas
      # d'identifiant à l'envoi ; ses routes de suivi prennent ces critères.
      record Key, form : String, siren : String, date_fin : String, echeance : String? = nil do
        def to_s(io : IO) : Nil
          io << form << ':' << siren << ':' << date_fin
          echeance.try { |day| io << ':' << day }
        end

        def self.parse(text : String) : Key?
          parts = text.split(':')
          return unless 3 <= parts.size <= 4 && parts[1].matches?(/\A\d{9}\z/)
          new(parts[0], parts[1], parts[2], parts[3]?.presence)
        end
      end

      def self.key(payload : Payload, due_on : String?) : Key
        form = form_key(payload.kind) || payload.kind
        echeance = payload.kind.in?("is_2571", "vat_ca3", "vat_ca12") ? due_on : nil
        Key.new(form, payload.identity.siren, payload.period_to, echeance)
      end

      # --- Liasse (API Balance) --------------------------------------------------

      def self.liasse(payload : Payload, submission : Submission, credentials : Credentials, source : String,
                      send_button : Bool) : String
        identity = payload.identity
        category = CATEGORIES[payload.forms]?
        lines = [] of {String, String?}
        lines << {"SOURCE", source}
        lines << {"VERSION", Teledec::VERSION}
        lines << {"EMAIL", credentials.email}
        lines << {"NOM", identity.company_name}
        lines << {"SIRET", siret(credentials, identity)}
        lines << {"CATEGORIE-FISCALE", category.try(&.[0])}
        lines << {"REEL-NORMAL-OU-SIMPLIFIE", category.try(&.[1])}
        lines << {"EXERCICE-DATE-DEBUT", compact_day(payload.period_from)}
        lines << {"EXERCICE-DATE-FIN", compact_day(payload.period_to)}
        lines << {"FORME-JURIDIQUE", legal_form(identity.legal_form)}
        lines << {"ADRESSE-NUMERO-RUE", identity.street}
        lines << {"ADRESSE-CODE-POSTAL", identity.postcode}
        lines << {"ADRESSE-VILLE", identity.city}
        lines << {"ADRESSE-PAYS", identity.country_code}
        lines << {"AFFICHAGE-BOUTON-ENVOYER", send_button ? "OUI" : "NON"}
        lines << {"REFERENCE", submission.reference}
        String.build do |io|
          lines.each do |(name, value)|
            text = clean(value.to_s)
            io << '#' << name << ' ' << text << '\n' unless text.empty?
          end
          (payload.balance || [] of Payload::BalanceRow).each do |row|
            io << clean(row.account) << ';' << clean(row.label) << ";0;0;" << row.debit << ';' << row.credit << ';'
            io << row.balance_debit << ';' << row.balance_credit << '\n'
          end
          if zones = liasse_zones(payload)
            io << {"zones_formulaires" => zones}.to_json << '\n'
          end
        end
      end

      # Cases jointes à la liasse (2035 préparée par le module `liberal`) :
      # zones `<code>_<formulaire>` par formulaire (`2035A`), montants en
      # euros entiers ; elles priment sur la ventilation de la balance.
      def self.liasse_zones(payload : Payload) : Hash(String, Hash(String, Int64))?
        boxes = payload.boxes || return
        zones = boxes.to_h do |form, values|
          name = form.delete('-')
          {name, values.to_h { |box, amount| {"#{box}_#{name}", integer(amount)} }}
        end
        zones.empty? ? nil : zones
      end

      # --- Marque blanche ---------------------------------------------------------

      def self.white_label(payload : Payload, submission : Submission, credentials : Credentials, now : Time) : String
        form = form_key(payload.kind) || raise TransportError.new("teledec.errors.transport.unsupported")
        identity = payload.identity
        year_end = submission.year_end.try { |day| Time.parse(day, "%F", Time::Location::UTC) } ||
                   Time.utc(Time.parse(payload.period_to, "%F", Time::Location::UTC).year, 12, 31)
        amount, block = case payload.kind
                        when "vat_ca3", "vat_ca12" then vat_block(payload, form)
                        when "das2"                then {0_i64, das2_block(payload, credentials)}
                        when "is_2571"             then advance_block(payload)
                        else                            balance_block(payload)
                        end
        JSON.build do |json|
          json.object do
            json.field "auth" do
              json.object do
                json.field "email", credentials.email
                json.field "timestamp", paris(now).to_s("%Y-%m-%dT%H:%M:%S")
                submission.callback_url.try { |url| json.field "url", url }
                json.field "bloquerSiIncoherence", false
                json.field "retournerPdf", false
                json.field "retournerLien", true
              end
            end
            json.field "identity" do
              json.object do
                json.field "siret", siret(credentials, identity) || identity.siren
                json.field "name", identity.company_name
                json.field "yearEndMonth", year_end.month
                json.field "yearEndDay", year_end.day
                present(json, "addressStreet", identity.street)
                present(json, "addressPostalCode", identity.postcode)
                present(json, "addressCity", identity.city)
                present(json, "addressCountry", identity.country_code)
                present(json, "legalForm", legal_form(identity.legal_form))
                present(json, "email", credentials.email)
                vat_regime(payload).try { |regime| json.field "regimeFiscalTVA", regime }
              end
            end
            json.field "period" do
              json.object do
                json.field "begin", payload.period_from
                json.field "end", payload.period_to
                json.field "reference", submission.reference
                submission.due_on.try { |day| json.field "echeance", day }
                json.field "montant", amount
                json.field "noPayment", amount <= 0
                json.field "millesime", millesime(payload)
              end
            end
            json.field form, block
          end
        end
      end

      def self.millesime(payload : Payload) : Int32
        payload.period_to[0, 4].to_i
      end

      # Bloc d'une déclaration de TVA : cases traduites (euros entiers),
      # mention « néant » si tout est nul ; rend aussi le montant à payer.
      private def self.vat_block(payload : Payload, form : String) : {Int64, Hash(String, JSON::Any)}
        boxes = payload.boxes.try(&.values.first?) || {} of String => String
        table = codes(form, millesime(payload))
        block = {} of String => JSON::Any
        boxes.each do |box, amount|
          value = integer(amount)
          next if value.zero?
          code = table[box]? || next
          block[code] = JSON::Any.new(value)
        end
        if form == "3517SCA12"
          boxes["sp"]?.try { |amount| block["SC"] = JSON::Any.new(integer(amount)) unless integer(amount).zero? }
          boxes["20"]?.try { |amount| block["HC"] = JSON::Any.new(integer(amount)) unless integer(amount).zero? }
        end
        if block.empty?
          block[form == "3517SCA12" ? "SD" : "KF"] = JSON::Any.new(true)
        end
        due = integer(boxes[form == "3517SCA12" ? "sp" : "32"]? || "0")
        {due, block}
      end

      # Relevé d'acompte d'IS (2571) : montant à payer.
      private def self.advance_block(payload : Payload) : {Int64, Hash(String, JSON::Any)}
        amount = integer(payload.details["amount"]? || "0")
        {amount, {"CA" => JSON::Any.new(amount), "CE" => JSON::Any.new(amount), "CH" => JSON::Any.new(amount)}}
      end

      # Relevé de solde d'IS (2572) : impôt de l'exercice (sans créance ni
      # contribution), acomptes versés, solde à payer ou excédent.
      private def self.balance_block(payload : Payload) : {Int64, Hash(String, JSON::Any)}
        tax = integer(payload.details["tax"]? || "0")
        advances = integer(payload.details["advances"]? || "0")
        due = {tax - advances, 0_i64}.max
        excess = {advances - tax, 0_i64}.max
        block = {} of String => JSON::Any
        {"GE" => tax, "RH" => tax, "RS" => tax, "RF" => tax, "RT" => advances, "PN" => due, "PQ" => excess,
         "AD" => due, "BD" => excess, "CA" => due, "DA" => excess}.each do |code, value|
          block[code] = JSON::Any.new(value)
        end
        {due, block}
      end

      # DAS2 : établissement déclarant, une répétition par bénéficiaire et
      # par nature (lettre de la DGFiP), totaux par nature.
      private def self.das2_block(payload : Payload, credentials : Credentials) : Hash(String, JSON::Any)
        identity = payload.identity
        lines = payload.das2 || [] of Payload::Das2Line
        block = {} of String => JSON::Any
        block["AA_3039_1"] = JSON::Any.new(identity.company_name)
        block["AA_3042_1"] = JSON::Any.new(identity.street) unless identity.street.empty?
        block["AA_3251_1"] = JSON::Any.new(identity.postcode) unless identity.postcode.empty?
        block["AA_3164_1"] = JSON::Any.new(identity.city) unless identity.city.empty?
        siret(credentials, identity).try { |value| block["AE"] = JSON::Any.new(value) }
        beneficiaries = [] of JSON::Any
        totals = Hash(String, Int64).new(0_i64)
        lines.each do |line|
          line.amounts.each do |nature, amount|
            value = integer(amount)
            next if value.zero?
            letter = DAS2_LETTERS[nature]? || "V"
            totals[letter] += value
            item = {} of String => JSON::Any
            item["AF_3039_1"] = JSON::Any.new(line.siret) unless line.siret.empty?
            item["AF_3036_1"] = JSON::Any.new(line.name)
            item["AG_3042_1"] = JSON::Any.new(line.address) unless line.address.empty?
            item["AG_3251_1"] = JSON::Any.new(line.postcode) unless line.postcode.empty?
            item["AG_3164_1"] = JSON::Any.new(line.city) unless line.city.empty?
            item["AH_4440_1"] = JSON::Any.new(line.profession) unless line.profession.empty?
            item["CA"] = JSON::Any.new(letter)
            item["BA"] = JSON::Any.new(value)
            beneficiaries << JSON::Any.new(item)
          end
        end
        block["repetitionDAS2TV"] = JSON::Any.new(beneficiaries)
        block["repetitionDAS2TotauxSommesVersees"] = JSON::Any.new(totals.map do |letter, total|
          JSON::Any.new({"UA" => JSON::Any.new(letter), "TA" => JSON::Any.new(total)})
        end)
        block
      end

      private def self.vat_regime(payload : Payload) : String?
        case payload.kind
        when "vat_ca3"  then payload.details["periodicity"]? == "quarter" ? "NormalTrimestriel" : "Normal"
        when "vat_ca12" then "Simplifie"
        end
      end

      # --- États et comptes-rendus ------------------------------------------------

      # État d'un dépôt d'après le statut de TELEDEC (insensible à la
      # casse : l'API rend `readyToBeSent` comme `ReadyToBeSent`).
      def self.state(status : String) : String
        case normalize(status)
        when "ok", "accepted", "completewithwarnings"   then "acknowledged"
        when "erreur", "rejected", "completewitherrors" then "rejected"
        else                                                 "pending"
        end
      end

      def self.normalize(status : String) : String
        status.strip.downcase.gsub(/[^a-z]/, "")
      end

      # Compte-rendu de la DGFiP (callback, `compteRendus` du suivi, liste
      # des comptes-rendus) : statut, motif, accusé en PDF.
      record Report, declaration_id : String, reference : String, status : String, reason : String,
        pdf : Bytes?, at : Time?, form : String do
        def state : String
          Formats.state(status)
        end
      end

      def self.report(any : JSON::Any) : Report
        hash = any.as_h? || raise TransportError.new("teledec.errors.transport.invalid")
        text = ->(name : String) do
          value = hash[name]?
          value.nil? || value.raw.nil? ? "" : (value.as_s? || value.raw.to_s)
        end
        status = [text.call("formulairesStatus"), text.call("status"), text.call("declarationStatus")]
          .find { |value| state(value) != "pending" } || text.call("status").presence || text.call("declarationStatus")
        pdf = text.call("pdf").presence.try do |encoded|
          Base64.decode(encoded)
        rescue Base64::Error
          nil
        end
        Report.new(text.call("declarationId"), text.call("reference"), status, reason(hash, text.call("statusLibelle")),
          pdf, parse_time(text.call("dateHeureDGFiP")), text.call("formulaire"))
      end

      # Motif lisible d'un rejet : erreurs de la DGFiP
      # (`declarationErreurs` : formulaire, champ, valeur, code, libellé),
      # sinon `erreurCode`/`erreurLibelle`, sinon le libellé du statut.
      def self.reason(hash : Hash(String, JSON::Any), label : String) : String
        errors = hash["declarationErreurs"]?.try(&.as_a?) || [] of JSON::Any
        parts = errors.compact_map do |error|
          item = error.as_h? || next
          get = ->(name : String) { item[name]?.try { |value| value.as_s? || value.raw.to_s }.to_s.strip }
          field = [get.call("formulaire"), get.call("champ")].reject(&.empty?).join(" ")
          field += " (#{get.call("champLibelle")})" unless get.call("champLibelle").empty?
          field += " = #{get.call("champValeur")}" unless get.call("champValeur").empty?
          message = [get.call("code"), get.call("libelle")].reject(&.empty?).join(" ")
          [field, message].reject(&.empty?).join(" : ").presence
        end
        return parts.join(" ; ") unless parts.empty?
        code = hash["erreurCode"]?.try { |value| value.as_s? || value.raw.to_s }.to_s
        libelle = hash["erreurLibelle"]?.try(&.as_s?).to_s
        [code, libelle].reject(&.empty?).join(" ").presence || label
      end

      # Compte-rendu qui fait foi : le plus récent (date de la DGFiP, à
      # défaut le dernier de la liste).
      def self.latest(reports : Array(Report)) : Report?
        return if reports.empty?
        dated = reports.select(&.at)
        dated.empty? ? reports.last : dated.max_by { |report| report.at || Time::UNIX_EPOCH }
      end

      # --- Outils -----------------------------------------------------------------

      PARIS = begin
        Time::Location.load("Europe/Paris")
      rescue Time::Location::InvalidLocationNameError | File::Error
        Time::Location.fixed("Europe/Paris", 3600)
      end

      # Heure française (horodatage exigé par la marque blanche).
      def self.paris(time : Time) : Time
        time.in(PARIS)
      end

      # Date et heure de TELEDEC (`2026-09-28T10:00:00`, heure française).
      def self.parse_time(text : String) : Time?
        return if text.empty?
        %w[%Y-%m-%dT%H:%M:%S %Y-%m-%d\ %H:%M:%S %Y-%m-%d].each do |format|
          return Time.parse(text[0, 19], format, PARIS).to_utc
        rescue Time::Format::Error
          next
        end
        nil
      end

      def self.integer(amount : String) : Int64
        Money.euros(Money.parse(amount)).to_i64
      end

      def self.compact_day(day : String) : String
        day.delete('-')
      end

      def self.legal_form(text : String) : String?
        clean = text.strip.upcase.gsub(/[^A-Z]/, "")
        return if clean.empty?
        LEGAL_FORMS[clean]? || "ZZZ"
      end

      # SIRET de l'établissement : celui des paramètres s'il est complet et
      # commence par le SIREN.
      def self.siret(credentials : Credentials, identity : Payload::Identity) : String?
        siret = credentials.siret.delete(' ')
        siret if siret.matches?(/\A\d{14}\z/) && (identity.siren.empty? || siret.starts_with?(identity.siren))
      end

      # Valeur d'une ligne d'identification ou de balance : ni fin de ligne
      # ni point-virgule.
      def self.clean(text : String) : String
        text.gsub(/[;\r\n]+/, " ").strip
      end

      private def self.present(json : JSON::Builder, name : String, value : String?) : Nil
        json.field name, value if value && !value.empty?
      end
    end
  end
end
