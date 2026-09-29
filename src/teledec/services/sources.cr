# SPDX-License-Identifier: AGPL-3.0-or-later

module Teledec
  # Sources des déclarations selon les modules actifs (ADR-003 D2 :
  # `depends_on_any "ACCOUNTING", "LIBERAL"` ; DECISIONS D-TDC2-001 à
  # D-TDC2-004).
  #
  # * Comptabilité active : toutes les déclarations (balance, liasses, TVA,
  #   DAS2, relevés d'IS, greffe) ; la 2035 joint les cases du module
  #   `liberal` s'il est actif.
  # * Module `liberal` seul : la liasse 2035 seulement, construite à partir
  #   de la 2035 préparée par `liberal`, sans balance. Aucune lecture du
  #   contrat `Partiduo::Api::Accounting` n'a lieu : chaque appel de ce
  #   contrat est précédé d'un contrôle de `accounting?`.
  module Sources
    ACCOUNTING = "ACCOUNTING"
    LIBERAL    = "LIBERAL"

    # Seul régime servi sans la Comptabilité : BNC, déclaration contrôlée
    # (2035).
    LIBERAL_TAX_SYSTEM = "bnc"

    # Refus d'une déclaration qui exige la Comptabilité.
    ACCOUNTING_REQUIRED = "teledec.errors.accounting_required"

    def self.accounting? : Bool
      active?(ACCOUNTING)
    end

    def self.liberal? : Bool
      active?(LIBERAL)
    end

    # Module actif sur l'instance (`Partiduo::Api::Modules`, acteur système) ;
    # module inconnu de la distribution : inactif.
    def self.active?(code : String) : Bool
      Partiduo::Api::Modules.get(Partiduo::Api::Actor.system, code).active
    rescue Partiduo::Api::NotFound
      false
    end

    # Régime d'imposition retenu : celui des paramètres ; sans la
    # Comptabilité et sans régime choisi, BNC (le module `liberal` ne sert
    # que la déclaration contrôlée).
    def self.tax_system(settings : Settings, accounting : Bool = accounting?) : String
      stored = settings.tax_system.to_s
      return stored if accounting || !stored.empty?
      LIBERAL_TAX_SYSTEM
    end

    # La sorte `kind` exige-t-elle la Comptabilité ? Toutes, sauf la liasse
    # d'un régime BNC (2035 préparée par `liberal`).
    def self.needs_accounting?(kind : String, tax_system : String) : Bool
      !(kind == "liasse" && tax_system == LIBERAL_TAX_SYSTEM)
    end

    # Sortes proposées pour le régime retenu.
    def self.kinds(tax_system : String, accounting : Bool = accounting?) : Array(String)
      return Config::KINDS if accounting
      Config::KINDS.reject { |kind| needs_accounting?(kind, tax_system) }
    end

    # Régimes d'imposition proposés dans les paramètres.
    def self.tax_systems(accounting : Bool = accounting?) : Array(String)
      accounting ? Config::TAX_SYSTEMS : [LIBERAL_TAX_SYSTEM]
    end
  end
end
