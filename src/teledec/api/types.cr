# SPDX-License-Identifier: AGPL-3.0-or-later

module Teledec
  module Api
    # --- Saisies ------------------------------------------------------------------

    # Préparer une déclaration :
    #
    # * `liasse`, `greffe`, `is_2571`, `is_2572` : `fiscal_year_id` ;
    #   `is_2571` : `number` (1 à 4) et `amount` (montant de l'acompte) ;
    #   `is_2572` : `amount` (impôt de l'exercice ; défaut : solde du compte
    #   695 de la balance) ; `greffe` : `confidential` (déclaration de
    #   confidentialité des comptes) ;
    # * `vat_ca3`, `vat_ca12` : `vat_return_id` (déclaration close de la
    #   Comptabilité) ;
    # * `das2` : `year` (année civile).
    record PrepareInput,
      kind : String,
      fiscal_year_id : Int64? = nil,
      year : Int32? = nil,
      number : Int32 = 0,
      vat_return_id : Int64? = nil,
      amount : BigDecimal? = nil,
      confidential : Bool = false

    # Paramètres ; `das2_accounts` : préfixe de compte → nature (`nil` garde
    # l'existant, vide rend les comptes par défaut).
    record SettingsInput,
      tax_system : String,
      vat_system : String,
      greffe : Bool = false,
      das2_accounts : Hash(String, String)? = nil,
      das2_threshold : BigDecimal? = nil

    # Identifiants de l'API partenaire. `api_key` vide garde la clé
    # enregistrée.
    record CredentialsInput, login : String, api_key : String, env : String = "sandbox"

    # Issue d'un dépôt fait hors de Partiduo (repli, sur le site de
    # TELEDEC) : `transmitted`, `acknowledged` (accusé facultatif en pièce
    # jointe) ou `rejected` (motif obligatoire).
    record OutcomeInput,
      status : String,
      reason : String = "",
      reference : String = "",
      receipt_filename : String? = nil,
      receipt_content_type : String? = nil,
      receipt : IO? = nil

    # --- Vues ---------------------------------------------------------------------

    # Contrôle d'une déclaration : `severity` `error` (bloque la
    # transmission) ou `warning` ; `key` clé i18n à paramètres.
    record ControlView, key : String, params : Hash(String, String), severity : String do
      include JSON::Serializable

      def error? : Bool
        severity == "error"
      end
    end

    record BalanceRowView, account : String, label : String, debit : BigDecimal, credit : BigDecimal,
      balance_debit : BigDecimal, balance_credit : BigDecimal

    record Das2LineView, card_code : String, name : String, siret : String, address : String,
      amounts : Hash(String, BigDecimal), total : BigDecimal

    record BoxView, form : String, box : String, amount : BigDecimal

    record EventView, status : String, detail : String, user_id : Int64?, at : Time

    # Dépôt : document préparé et son suivi.
    record FilingView,
      id : Int64,
      key : String,
      kind : String,
      forms : Array(String),
      fiscal_year_id : Int64?,
      year : Int32,
      number : Int32,
      period_from : Time,
      period_to : Time,
      due_on : Time?,
      vat_return_id : Int64?,
      status : String,
      fingerprint : String,
      controls : Array(ControlView),
      company_name : String,
      siren : String,
      balance : Array(BalanceRowView),
      previous_balance_rows : Int32,
      boxes : Array(BoxView),
      das2 : Array(Das2LineView),
      details : Hash(String, String),
      remote_id : String,
      manual : Bool,
      rejection_reason : String,
      last_error : String,
      receipt_attachment_id : Int64?,
      prepared_at : Time,
      transmitted_at : Time?,
      acknowledged_at : Time?,
      rejected_at : Time? do
      def ready? : Bool
        controls.none?(&.error?)
      end

      def errors : Array(ControlView)
        controls.select(&.error?)
      end

      def warnings : Array(ControlView)
        controls.reject(&.error?)
      end

      def kind_key : String
        "teledec.kinds.#{kind}"
      end

      def status_key : String
        "teledec.statuses.#{status}"
      end

      def transmittable? : Bool
        status == "prepared" || status == "rejected"
      end

      def total_debit : BigDecimal
        balance.sum(BigDecimal.new(0), &.balance_debit)
      end

      def total_credit : BigDecimal
        balance.sum(BigDecimal.new(0), &.balance_credit)
      end
    end

    # En-tête d'un dépôt pour les listes (`Api.filings`) : statut, période,
    # contrôles, sans le document (balance, cases, DAS2).
    record FilingSummaryView,
      id : Int64,
      key : String,
      kind : String,
      forms : Array(String),
      fiscal_year_id : Int64?,
      year : Int32,
      number : Int32,
      period_from : Time,
      period_to : Time,
      due_on : Time?,
      status : String,
      controls : Array(ControlView),
      remote_id : String,
      manual : Bool,
      prepared_at : Time,
      transmitted_at : Time?,
      acknowledged_at : Time?,
      rejected_at : Time? do
      def ready? : Bool
        controls.none?(&.error?)
      end

      def errors : Array(ControlView)
        controls.select(&.error?)
      end

      def warnings : Array(ControlView)
        controls.reject(&.error?)
      end

      def kind_key : String
        "teledec.kinds.#{kind}"
      end

      def status_key : String
        "teledec.statuses.#{status}"
      end
    end

    # Échéance d'un exercice : déclaration attendue, date limite, dépôt
    # s'il existe. `vat_return_id` : déclaration de TVA close de la
    # Comptabilité pour la période (sinon à préparer au lot 4 d'abord).
    record DeadlineView,
      key : String,
      kind : String,
      forms : Array(String),
      fiscal_year_id : Int64?,
      year : Int32,
      number : Int32,
      period_from : Time,
      period_to : Time,
      due_on : Time,
      vat_return_id : Int64?,
      filing_id : Int64?,
      status : String? do
      def kind_key : String
        "teledec.kinds.#{kind}"
      end

      def overdue?(today : Time) : Bool
        status.nil? && due_on < today
      end
    end

    # Paramètres ; `login` est vide pour qui n'a pas
    # `teledec.settings.manage`.
    record SettingsView,
      tax_system : String,
      vat_system : String,
      greffe : Bool,
      das2_accounts : Hash(String, String),
      das2_threshold : BigDecimal,
      env : String,
      login : String,
      key_stored : Bool,
      checked_at : Time?,
      transport : String?,
      forms : Array(String)

    # Fichier produit (balance de repli, document JSON, accusé).
    record FileView, filename : String, content_type : String, content : Bytes
  end
end
