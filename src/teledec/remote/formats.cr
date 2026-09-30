# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"
require "base64"

module Teledec
  module Remote
    # Traduction du document neutre (`Teledec::Payload`) dans les formats de
    # l'API partenaire de TELEDEC, et lecture de ses réponses. Sources :
    # synthèse de l'API relevée sur le portail partenaires, spécifications
    # JSON des formulaires (codes par millésime) et réponses de TELEDEC du
    # 29 septembre 2026 (DECISIONS D-TDC3-*) ; ce qui reste incertain est
    # consigné dans BLOCAGES (B-TDC-004).
    #
    # * Liasse : API Balance (`POST /service/liasse`), texte en trois
    #   sections — identification `#CLE valeur` (compte de l'entreprise :
    #   `#EMAIL`, `#MOT-DE-PASSE` bcrypt), balance `compte;libellé;ouv.
    #   débit;ouv. crédit;mvt débit;mvt crédit;solde débit;solde crédit`,
    #   bloc JSON facultatif sur plusieurs lignes (`zones_formulaires`, clés
    #   = code de la case seul, sauf 2065, 2031 et 2035 : `HA_2065` ;
    #   `informations_supplementaires`) ; sans balance, la section de
    #   balance est absente (D-TDC7-001).
    # * TVA, DAS2, IS : API marque blanche
    #   (`POST /service/declaration-marque-blanche`), JSON `auth`,
    #   `identity`, `period` et un bloc par formulaire en clés/valeurs ; la
    #   DAS2, formulaire principal (annexe G de la page marque blanche),
    #   part seule, au millésime de sa campagne (D-TDC6-001).
    #
    # Millésimes : `Millesime` ; clés et types conformes aux schémas JSON
    # de TELEDEC (`Schemas`, D-TDC6-002 à 004).
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
      # formulaire `3310CA3`, par premier millésime d'application
      # (réponses de TELEDEC du 29 septembre 2026, D-TDC3-003 ; clés : rang
      # du millésime, `Millesime.rank`) : A4
      # importations `DK`, A5 sorties de régime suspensif `KV`, B2
      # acquisitions intracommunautaires `CC` ; `KW`, `KX`, `KZ` sont les
      # lignes E4, E5, F1 (opérations non imposables, pour information) ;
      # taxes assimilées de l'annexe 3310-A en ligne 29 (`KB`). Il n'y a pas
      # de ligne 14 chez TELEDEC : les opérations aux taux particuliers se
      # déclarent taux par taux (`ANNEX_CODES`).
      CA3_CODES = {
        202401 => {
          "A1" => "CA", "A2" => "CB", "A3" => "KH", "A4" => "DK", "A5" => "KV", "B2" => "CC", "B4" => "CG",
          "B5" => "CE", "E1" => "DA", "E2" => "DB", "E4" => "KW", "E5" => "KX", "F1" => "KZ", "F2" => "DC",
          "F6" => "DD",
          "08.base" => "FP", "08.tax" => "GP", "09.base" => "FB", "09.tax" => "GB", "9B.base" => "FR", "9B.tax" => "GR",
          "10.base" => "FM", "10.tax" => "GM", "11.base" => "FN", "11.tax" => "GN", "13.base" => "FC", "13.tax" => "GC",
          "15" => "GG", "16" => "GH", "17" => "GJ", "19" => "HA", "20" => "HB", "21" => "HC", "22" => "HD",
          "23" => "HG", "25" => "JA", "26" => "JB", "27" => "JC", "28" => "KA", "29" => "KB", "32" => "KE",
        },
      }

      # Opérations aux taux particuliers (ligne 14 de Partiduo, détaillée
      # taux par taux par l'annexe, D-R5-006) → codes TELEDEC de la CA3
      # (base, taxe), par code de taux du jeu initial français :
      # 2,10 % en métropole, 0,90 % et 13 % en Corse, 1,05 % et 1,75 % dans
      # les DOM. Un autre taux particulier n'a pas de code sûr : non
      # transmissible (contrôle bloquant).
      ANNEX_CODES = {
        "TP021" => {"MF", "ME"},
        "COR09" => {"BE", "MA"},
        "COR13" => {"NN", "NP"},
        "DPRS"  => {"BP", "CP"},
        "DOM1"  => {"BQ", "CQ"},
      }

      # Case de Partiduo d'une ligne de l'annexe : `14.<code du taux>.base`
      # ou `14.<code du taux>.tax`.
      ANNEX_BOX = /\A14\.([A-Z0-9_]+)\.(base|tax)\z/

      # Cases de la CA12 de Partiduo (numérotées comme la CA3) → codes
      # TELEDEC du formulaire `3517SCA12`. La 3517-S ne porte que les bases
      # et taxes par taux, sans cadre A : A1, A2, A4, A5, B2 et B5 (propres
      # à la CA3, D-TDC3-003) et la ligne 17 de Partiduo (« dont TVA sur
      # acquisitions intracommunautaires », comprise dans la ligne 08) ne se
      # transmettent pas (codes vérifiés sur les schémas 3517SCA12 2024 à
      # 202601, tous entiers sauf la mention néant `SD`). Taux particuliers : une seule ligne (`EJ`, `FJ`).
      # La ligne 17 (remboursements provisionnels, `GA`) et la ligne 29
      # (crédit, `LB`) citées par TELEDEC suivent la numérotation de la
      # 3517-S : Partiduo ne calcule pas de remboursement provisionnel, son
      # crédit est sa ligne 25 (`LB`) ; ses taxes assimilées (ligne 29 de
      # Partiduo) n'ont pas de total sur la 3517-S : non transmissibles.
      CA12_CODES = {
        202401 => {
          "08.base" => "EW", "08.tax" => "FW", "09.base" => "EF", "09.tax" => "FF", "9B.base" => "GF", "9B.tax" => "GH",
          "10.base" => "EU", "10.tax" => "FU", "11.base" => "EV", "11.tax" => "FV", "13.base" => "EG", "13.tax" => "FG",
          "A3" => "EH", "B4" => "VN", "E1" => "EB", "E2" => "EC", "F2" => "ED", "F6" => "EA",
          "15" => "GB", "16" => "GC", "19" => "JA", "20" => "HA", "21" => "KB", "22" => "KA", "23" => "KD",
          "25" => "LB", "28" => "LA", "ac" => "MM", "sp" => "NA", "ex" => "NB", "14.base" => "EJ", "14.tax" => "FJ",
        },
      }

      # Cases sans code qui ne sont que des totaux ou des détails repris
      # ailleurs.
      IGNORED = {"3517SCA12" => %w[A1 A2 A4 A5 B2 B5 17]}

      # Zones connues des formulaires de la liasse que Partiduo remplit
      # (2035 préparée par `liberal`), par formulaire puis par premier
      # millésime d'application (rang, `Millesime.rank`), relevées dans les
      # schémas JSON de TELEDEC (2035, 2035A, 2035B de 2024 à 2026,
      # D-TDC6-004) : la 2035-B gagne AC en 2025, AD, AE, AF, AG, DP, DQ,
      # DR, DS en 2026 et y perd DM. TELEDEC ignore *sans erreur* une clé
      # inconnue : toute case hors de ces listes est refusée à la
      # préparation (`teledec.controls.zone_unknown`) et à l'envoi
      # (D-TDC3-002).
      ZONE_2035A = %w[
        AA AB AC AD AE AF AG BA BB BC BD BE BF BG BH BJ BK BL BM BN BP BR BS BT BU BV EA EB EC ED EE EF EG EJ EK EL EM
        EN FC GF GJ GL AW
      ]
      ZONE_2035B = %w[CA CB CC CD CE CF CG CH CK CL CM CN CP CR CS CT CX CY CZ DG DJ DK DL GK HC HE JA AB]
      ZONE_CODES = {
        "2035-A" => {202401 => ZONE_2035A},
        "2035-B" => {
          202401 => ZONE_2035B + %w[DM],
          202501 => ZONE_2035B + %w[AC DM],
          202601 => ZONE_2035B + %w[AC AD AE AF AG DP DQ DR DS],
        },
        "2035" => {202401 => %w[AA AB FG FH FJ FV MG NG NH NN NP NQ NR AP AL AM AJ AN AF AR AG AH AS]},
      }

      # Formulaires dont les zones portent le suffixe du formulaire dans le
      # schéma de TELEDEC (`HA_2065`, `FJ_2035` : les schémas de la 2035
      # l'ont aussi, D-TDC6-004) ; ailleurs, le code de la case seul.
      SUFFIXED_ZONE_FORMS = %w[2065 2031 2035]

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

      # Régime d'imposition du dossier → régime fiscal complet de TELEDEC
      # (`fullRegimeFiscal` de `creation-entreprise`, champ facultatif de
      # cette route, défaut `ISRS` chez TELEDEC) : l'entreprise créée avant
      # un dépôt porte son vrai régime (D-TDC5-002, D-TDC6-005). Jamais dans
      # l'identité d'une déclaration en marque blanche : réservé à l'option
      # « EDI Requête » ; TELEDEC y déduit le régime des formulaires.
      # Valeurs de la liste de référence de TELEDEC (« Liste régimes
      # fiscaux », base de connaissances partenaires) : le BNC s'écrit
      # `BNCDC` (déclaration contrôlée) ; `BNC` est refusé par
      # `creation-entreprise` (« Misformatted JSON », D-TDC8-001).
      FULL_REGIMES = {
        "is_rsi" => "ISRS", "is_rn" => "ISRN", "bic_rsi" => "BICRS", "bic_rn" => "BICRN", "bnc" => "BNCDC",
        "sci" => "RF72S",
      }

      # Liste complète des régimes fiscaux admis par TELEDEC.
      KNOWN_REGIMES = Set{"ISRS", "ISRN", "BICRS", "BICRN", "BABS", "BABN", "BICMN", "BICMS", "BNCDC", "RF72S", "RF72C",
                          "ISGM", "ISGMSEULS", "ISGT"}

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

      # Table des codes d'un formulaire de TVA pour un millésime visé
      # (rang, `Millesime.target`) : la plus récente applicable, la plus
      # ancienne avant la première.
      def self.codes(form : String, target : Int32) : Hash(String, String)
        tables = form == "3517SCA12" ? CA12_CODES : CA3_CODES
        tables[tables.keys.select(&.<=(target)).max? || tables.keys.min]
      end

      # Cases non nulles de TVA qu'aucun code TELEDEC ne reçoit (contrôle
      # bloquant à la préparation).
      def self.unmapped(kind : String, boxes : Hash(String, String), target : Int32) : Array(String)
        form = form_key(kind) || return [] of String
        return [] of String unless kind.starts_with?("vat_")
        boxes.compact_map do |box, amount|
          next if Money.parse(amount).zero?
          box unless vat_code(form, box, boxes, target) || vat_ignored?(form, box, boxes)
        end
      end

      # Code TELEDEC d'une case de TVA de Partiduo, `nil` s'il n'y en a pas.
      # CA3 : une ligne de l'annexe (`14.<taux>.base|tax`) va à la case de
      # son taux.
      def self.vat_code(form : String, box : String, boxes : Hash(String, String), target : Int32) : String?
        if form == "3310CA3" && (match = ANNEX_BOX.match(box))
          pair = ANNEX_CODES[match[1]]? || return
          return match[2] == "base" ? pair[0] : pair[1]
        end
        codes(form, target)[box]?
      end

      # Case qui ne se transmet pas, sans être une omission : total ou
      # détail repris ailleurs. CA3 : la ligne 14 quand l'annexe la détaille
      # taux par taux ; CA12 : les lignes de l'annexe (la 3517-S n'a qu'une
      # ligne de taux particuliers).
      def self.vat_ignored?(form : String, box : String, boxes : Hash(String, String)) : Bool
        return true if (IGNORED[form]? || [] of String).includes?(box)
        return ANNEX_BOX.matches?(box) if form == "3517SCA12"
        box.in?("14.base", "14.tax") && boxes.keys.any?(&.matches?(ANNEX_BOX))
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

      # `account` : adresse du compte de l'entreprise chez TELEDEC
      # (`Account.email`), avec le haché bcrypt de son mot de passe. La
      # liasse n'a pas de champ d'adresse de rappel : ses rappels vont à
      # l'adresse configurée chez TELEDEC pour le partenaire (D-TDC3-006).
      def self.liasse(payload : Payload, submission : Submission, credentials : Credentials, source : String,
                      send_button : Bool, account : String) : String
        identity = payload.identity
        category = CATEGORIES[payload.forms]?
        lines = [] of {String, String?}
        lines << {"SOURCE", source}
        lines << {"VERSION", Teledec::VERSION}
        lines << {"EMAIL", account}
        lines << {"MOT-DE-PASSE", credentials.password_hash}
        lines << {"NOM", identity.company_name}
        lines << {"SIRET", siret(credentials, identity)}
        lines << {"CATEGORIE-FISCALE", category.try(&.[0])}
        lines << {"REEL-NORMAL-OU-SIMPLIFIE", category.try(&.[1])}
        lines << {"EXERCICE-DATE-DEBUT", compact_day(payload.period_from)}
        lines << {"EXERCICE-DATE-FIN", compact_day(payload.period_to)}
        lines << {"MILLESIME", millesime(payload).to_s}
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
          liasse_json(payload).try { |json| io << json << '\n' }
        end
      end

      # Section JSON de la liasse, dans la forme de la documentation de
      # l'API Balance (D-TDC7-001) : objet sur plusieurs lignes, `{` seul
      # sur la première et `}` seul sur la dernière, avec ses deux blocs
      # `zones_formulaires` et `informations_supplementaires` (vide : Partiduo
      # n'en transmet rien) ; `nil` sans case à joindre. Elle suit la
      # dernière ligne de balance, ou l'identification quand la liasse n'a
      # pas de balance (2035 d'un libéral sans Comptabilité) : la section de
      # balance est alors absente, sans ligne vide ni ligne d'en-tête.
      def self.liasse_json(payload : Payload) : String?
        zones = liasse_zones(payload) || return
        {"zones_formulaires" => zones, "informations_supplementaires" => {} of String => String}.to_pretty_json
      end

      # Cases jointes à la liasse (2035 préparée par le module `liberal`) :
      # zones par formulaire (`2035A`), clé = code de la case seul
      # (`"2035A": {"AA": …}`), sauf pour la 2065, la 2031 et la 2035
      # (`HA_2065`, `FJ_2035`) ;
      # montants en euros entiers ; elles priment sur la ventilation de la
      # balance. Une case hors du schéma relevé est refusée
      # (`teledec.errors.transport.zone_unknown`) : TELEDEC l'ignorerait
      # sans le dire.
      def self.liasse_zones(payload : Payload) : Hash(String, Hash(String, Int64))?
        boxes = payload.boxes || return
        unknown = unknown_zones(boxes, millesime_target(payload))
        unless unknown.empty?
          raise TransportError.new("teledec.errors.transport.zone_unknown", {"zones" => unknown.join(", ")})
        end
        zones = boxes.to_h do |form, values|
          name = form.delete('-')
          suffixed = SUFFIXED_ZONE_FORMS.includes?(name)
          {name, values.to_h { |box, amount| {suffixed ? "#{box}_#{name}" : box, integer(amount)} }}
        end
        zones.empty? ? nil : zones
      end

      # Cases hors du schéma relevé (`ZONE_CODES`) pour le millésime visé
      # `target` (rang), sous la forme `<formulaire> <case>` ; un formulaire
      # sans schéma relevé n'a aucune case connue.
      def self.unknown_zones(boxes : Hash(String, Hash(String, String)), target : Int32) : Array(String)
        boxes.flat_map do |form, values|
          known = zone_codes(form, target)
          values.keys.reject { |box| known.includes?(box) }.map { |box| "#{form} #{box}" }
        end
      end

      # Zones connues d'un formulaire au millésime visé : la table la plus
      # récente applicable, la plus ancienne avant la première.
      def self.zone_codes(form : String, target : Int32) : Array(String)
        tables = ZONE_CODES[form]? || return [] of String
        tables[tables.keys.select(&.<=(target)).max? || tables.keys.min]
      end

      # --- Marque blanche ---------------------------------------------------------

      # `account` : adresse du compte de l'entreprise chez TELEDEC
      # (`auth.email`) ; l'email de contact des paramètres va dans
      # l'identité.
      def self.white_label(payload : Payload, submission : Submission, credentials : Credentials, now : Time,
                           account : String) : String
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
                json.field "email", account
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
                # Année de campagne (D-TDC6-001) ; TELEDEC déduit le palier
                # de TVA des dates de la période.
                json.field "millesime", millesime(payload, submission.due_on)
              end
            end
            json.field form, block
          end
        end
      end

      # Régime d'imposition du dossier : celui noté dans le document
      # (`details["tax_system"]`), sinon celui des formulaires d'une
      # liasse ; `nil` s'il est inconnu.
      def self.tax_system(payload : Payload) : String?
        noted = payload.details["tax_system"]?.presence
        return noted if noted && FULL_REGIMES.has_key?(noted)
        Config::FORMS.key_for?(payload.forms) if payload.kind == "liasse"
      end

      # Année de campagne du dépôt (`period.millesime`, `#MILLESIME`) :
      # `Millesime.campaign`.
      def self.millesime(payload : Payload, due_on : String? = nil) : Int32
        Millesime.campaign(payload.kind, payload.period_to, due_on)
      end

      # Millésime visé (rang, palier de TVA compris) : schéma et tables de
      # codes.
      def self.millesime_target(payload : Payload, due_on : String? = nil) : Int32
        Millesime.target(payload.kind, payload.period_to, due_on)
      end

      # Bloc d'une déclaration de TVA : cases traduites (euros entiers),
      # mention « néant » si tout est nul ; rend aussi le montant à payer.
      private def self.vat_block(payload : Payload, form : String) : {Int64, Hash(String, JSON::Any)}
        # Totaux recalculés sur les cases arrondies (déjà fait à la
        # préparation ; sans effet sur un document cohérent).
        boxes = VatTotals.coherent(payload.kind, payload.boxes.try(&.values.first?) || {} of String => String)
        target = millesime_target(payload)
        block = {} of String => JSON::Any
        boxes.each do |box, amount|
          value = integer(amount)
          next if value.zero? || vat_ignored?(form, box, boxes)
          code = vat_code(form, box, boxes, target) || next
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

      # DAS2 : établissement déclarant — désignation `AA_3036_1`, SIRET
      # `AA_3039_1` et `AE` (schéma DAS2 2026 : 3036 est le nom, 3039
      # l'identifiant, D-TDC6-004) —, *une* répétition `repetitionDAS2TV`
      # par bénéficiaire (SIRET de l'établissement en `AD`), ses natures dans
      # le sous-tableau `repetitionDAS2MontantSommesVersees` (`CA` lettre de
      # la DGFiP, `BA` montant), totaux par nature (D-TDC3-004). Personne
      # physique (fiche fournisseur `individual`) : nom (`AE_3036_1`),
      # prénoms (`AE_3036_2`) et date de naissance (`AI`, `AAAA-MM-JJ`,
      # forme à confirmer sur le stage, BLOCAGES B-TDC-004) ; personne
      # morale : raison sociale (`AF_3036_1`) et SIRET (`AF_3039_1`).
      # DECISIONS D-R5-002.
      private def self.das2_block(payload : Payload, credentials : Credentials) : Hash(String, JSON::Any)
        identity = payload.identity
        lines = payload.das2 || [] of Payload::Das2Line
        block = {} of String => JSON::Any
        block["AA_3036_1"] = JSON::Any.new(identity.company_name)
        block["AA_3042_1"] = JSON::Any.new(identity.street) unless identity.street.empty?
        block["AA_3251_1"] = JSON::Any.new(identity.postcode) unless identity.postcode.empty?
        block["AA_3164_1"] = JSON::Any.new(identity.city) unless identity.city.empty?
        establishment = siret(credentials, identity)
        establishment.try do |number|
          block["AA_3039_1"] = JSON::Any.new(number)
          block["AE"] = JSON::Any.new(number)
        end
        beneficiaries = [] of JSON::Any
        totals = Hash(String, Int64).new(0_i64)
        lines.each do |line|
          amounts = [] of JSON::Any
          line.amounts.each do |nature, amount|
            value = integer(amount)
            next if value.zero?
            # Nature sans lettre : refusée plutôt que déclarée en « autres »
            # (contrôle bloquant à la préparation, `das2_nature`).
            letter = DAS2_LETTERS[nature]? ||
                     raise TransportError.new("teledec.errors.transport.das2_nature", {"nature" => nature})
            totals[letter] += value
            amounts << JSON::Any.new({"CA" => JSON::Any.new(letter), "BA" => JSON::Any.new(value)})
          end
          next if amounts.empty?
          item = {} of String => JSON::Any
          establishment.try { |number| item["AD"] = JSON::Any.new(number) }
          if line.person?
            item["AE_3036_1"] = JSON::Any.new(line.last_name)
            item["AE_3036_2"] = JSON::Any.new(line.first_names)
            item["AI"] = JSON::Any.new(line.birth_date) unless line.birth_date.empty?
          else
            item["AF_3036_1"] = JSON::Any.new(line.name)
            item["AF_3039_1"] = JSON::Any.new(line.siret) unless line.siret.empty?
          end
          item["AG_3042_1"] = JSON::Any.new(line.address) unless line.address.empty?
          item["AG_3251_1"] = JSON::Any.new(line.postcode) unless line.postcode.empty?
          item["AG_3164_1"] = JSON::Any.new(line.city) unless line.city.empty?
          item["AH_4440_1"] = JSON::Any.new(line.profession) unless line.profession.empty?
          item["repetitionDAS2MontantSommesVersees"] = JSON::Any.new(amounts)
          beneficiaries << JSON::Any.new(item)
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
      # casse : l'API rend `readyToBeSent` comme `ReadyToBeSent`) : `OK` ou
      # `Accepted`, accepté par la DGFiP ; `ERREUR` ou `Rejected`, rejeté par
      # la DGFiP ; tout autre état est en attente — `CompleteWithErrors` et
      # `CompleteWithWarnings` sont les contrôles internes de TELEDEC *avant*
      # l'envoi (bloquants, non bloquants), pas des retours de la DGFiP
      # (réponses de TELEDEC du 29 septembre 2026, D-TDC3-005).
      def self.state(status : String) : String
        case normalize(status)
        when "ok", "accepted"     then "acknowledged"
        when "erreur", "rejected" then "rejected"
        else                           "pending"
        end
      end

      def self.normalize(status : String) : String
        status.strip.downcase.gsub(/[^a-z]/, "")
      end

      # Compte-rendu de la DGFiP (callback, `compteRendus` du suivi, liste
      # des comptes-rendus) : statut, motif, accusé en PDF.
      #
      # `declaration_type` : type du rappel chez TELEDEC (`TVA`, `Liasse`,
      # `Paiement`…) ; un rappel de paiement ne dit rien de la déclaration.
      record Report, declaration_id : String, reference : String, status : String, reason : String,
        pdf : Bytes?, at : Time?, form : String, declaration_type : String = "" do
        def state : String
          Formats.state(status)
        end

        # Compte-rendu d'un paiement (prélèvement), pas de la déclaration.
        def payment? : Bool
          Formats.normalize(declaration_type) == "paiement"
        end

        # Compte-rendu d'un autre envoi que celui dont la référence est
        # `expected` : référence renseignée et différente.
        def stale?(expected : String) : Bool
          !reference.empty? && !expected.empty? && reference != expected
        end
      end

      # Type de rappel (`declarationType`) de chaque sorte de dépôt
      # (réponses de TELEDEC du 29 septembre 2026, D-TDC3-005) : la DAS2 est
      # une déclaration `part`, les relevés 2571 et 2572 des `paiement`
      # (non distingués entre eux).
      DECLARATION_TYPES = {"vat_ca3" => "tva", "vat_ca12" => "tva", "liasse" => "liasse", "das2" => "part",
                           "is_2571" => "paiement", "is_2572" => "paiement", "greffe" => "greffe"}

      # Sorte de dépôt d'un formulaire de suivi (`liasse`, `3310CA3`…).
      def self.kind_of_form(form : String) : String?
        FORM_KEYS.key_for?(form)
      end

      # Le compte-rendu `report` concerne-t-il la déclaration d'un dépôt de
      # sorte `kind` ? Type attendu s'il est donné ; sans type, oui, sauf un
      # rappel de paiement pour une autre sorte qu'un relevé d'IS.
      def self.concerns?(report : Report, kind : String?) : Bool
        type = normalize(report.declaration_type)
        expected = kind.try { |value| DECLARATION_TYPES[value]? }
        return type == expected if expected && !type.empty?
        !report.payment? || expected == "paiement"
      end

      # Identité de l'entreprise pour `POST /service/creation-entreprise`
      # (compte en marque blanche, D-TDC3-007), avec son régime fiscal et
      # son régime de TVA quand le document les donne (D-TDC5-002).
      def self.company_identity(payload : Payload, credentials : Credentials, year_end : Time) : Hash(String, String | Int32)
        identity = payload.identity
        hash = {"siren" => identity.siren, "name" => identity.company_name, "yearEndMonth" => year_end.month,
                "yearEndDay" => year_end.day} of String => String | Int32
        {"addressStreet" => identity.street, "addressPostalCode" => identity.postcode, "addressCity" => identity.city,
         "addressCountry" => identity.country_code, "legalForm" => legal_form(identity.legal_form).to_s,
         "email" => credentials.email}.each { |name, value| hash[name] = value unless value.empty? }
        tax_system(payload).try { |system| FULL_REGIMES[system]?.try { |regime| hash["fullRegimeFiscal"] = regime } }
        vat_regime(payload).try { |regime| hash["regimeFiscalTVA"] = regime }
        hash
      end

      def self.report(any : JSON::Any) : Report
        hash = any.as_h? || raise TransportError.new("teledec.errors.transport.invalid")
        text = ->(name : String) do
          value = hash[name]?
          value.nil? || value.raw.nil? ? "" : (value.as_s? || value.raw.to_s)
        end
        # Statut à suivre (réponses de TELEDEC du 29 septembre 2026) : celui
        # de la déclaration (`declarationStatus`), sinon `status` — `SENT`
        # soumis, `OK` accepté, `ERREUR` rejeté par la DGFiP ; à défaut, le
        # statut des formulaires.
        status = text.call("declarationStatus").presence || text.call("status").presence ||
                 text.call("formulairesStatus")
        pdf = text.call("pdf").presence.try do |encoded|
          Base64.decode(encoded)
        rescue Base64::Error
          nil
        end
        Report.new(text.call("declarationId"), text.call("reference"), status, reason(hash, text.call("statusLibelle")),
          pdf, parse_time(text.call("dateHeureDGFiP")), text.call("formulaire"), text.call("declarationType"))
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
