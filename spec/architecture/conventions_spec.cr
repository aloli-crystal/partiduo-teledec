# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"
require "../../lib/partiduo-ui-bulma/scripts/api_boundary"

private def source_files(pattern : String) : Array(String)
  Dir.glob(File.join(Teledec::SpecSupport::ROOT, pattern)).reject(&.includes?("/lib/")).sort!
end

private def flatten_keys(value : YAML::Any, prefix : String = "") : Array(String)
  if hash = value.as_h?
    hash.flat_map { |key, child| flatten_keys(child, prefix.empty? ? key.as_s : "#{prefix}.#{key.as_s}") }
  else
    [prefix]
  end
end

describe "Conventions de l'extension TELEDEC" do
  it "ouvre chaque fichier source par l'en-tête SPDX" do
    missing = (source_files("{src,ui,spec,config,scripts}/**/*.{cr,sh}") + source_files("*.cr")).reject do |path|
      lines = File.read_lines(path)
      (path.ends_with?(".sh") ? lines[1]? : lines.first?) == "# SPDX-License-Identifier: AGPL-3.0-or-later"
    end
    missing += source_files("ui/**/*.html").reject do |path|
      File.read(path).starts_with?("{# SPDX-License-Identifier: AGPL-3.0-or-later")
    end
    missing.should be_empty
  end

  it "a les mêmes clés de traduction en fr, en et nl" do
    %w[src/teledec/locales ui/bulma/locales].each do |dir|
      keys = Partiduo::LOCALES.to_h do |locale|
        tree = YAML.parse(File.read(File.join(Teledec::SpecSupport::ROOT, dir, "#{locale}.yml")))
        {locale, flatten_keys(tree[locale]).sort}
      end
      keys["en"].should eq(keys["fr"])
      keys["nl"].should eq(keys["fr"])
    end
  end

  it "traduit toute clé citée par le code et les gabarits de l'extension" do
    cited = source_files("{src,ui}/**/*.{cr,html}").flat_map do |path|
      File.read(path).scan(/["'](teledec(?:_ui)?\.[a-z_0-9]+(?:\.[a-z0-9_]+)+)["']/).map(&.[1])
    end.uniq! - Partiduo::Modules[Teledec::CODE].permissions
    cited.size.should be > 60
    dynamic = [] of String
    Teledec::Api::KINDS.each { |code| dynamic << "teledec.kinds.#{code}" }
    (Teledec::Api::STATUSES + ["error"]).each { |code| dynamic << "teledec.statuses.#{code}" }
    Teledec::Api::TAX_SYSTEMS.each { |code| dynamic << "teledec.tax_systems.#{code}" }
    Teledec::Api::VAT_SYSTEMS.each { |code| dynamic << "teledec.vat_systems.#{code}" }
    Teledec::Api::ENVIRONMENTS.each { |code| dynamic << "teledec.environments.#{code}" }
    Teledec::Api::DAS2_NATURES.each { |code| dynamic << "teledec.das2_natures.#{code}" }
    %w[amount tax advances balance threshold].each { |code| dynamic << "teledec_ui.details.#{code}" }
    Partiduo::Modules[Teledec::CODE].permissions.each do |name|
      dynamic << "teledec.permissions.#{name.lchop("teledec.")}"
    end
    missing = Partiduo::LOCALES.flat_map do |locale|
      I18n.with_locale(locale) do
        (cited + dynamic).reject(&.ends_with?(".")).select { |key| I18n.t(key).includes?("missing") && I18n.t(key, count: 2).includes?("missing") }
          .map { |key| "#{locale}:#{key}" }
      end
    end
    missing.should be_empty
  end

  it "ne cite pas le logiciel d'origine hors *.adoc et *.md" do
    name = "noa" + "lyss"
    output = IO::Memory.new
    Process.run("git", ["grep", "-il", name, "--", ".", ":!*.adoc", ":!*.md"],
      chdir: Teledec::SpecSupport::ROOT, output: output)
    output.to_s.lines.should be_empty
  end

  it "range ses tables sous le préfixe teledec_ (ADR-003 D5)" do
    [Teledec::Settings, Teledec::Filing, Teledec::FilingEvent].map(&.db_table)
      .should eq(%w[teledec_settings teledec_filing teledec_filing_event])
  end

  it "ne parle au cœur, depuis ui/bulma, que par Partiduo::Api (ADR-005 D3)" do
    root = Teledec::SpecSupport::ROOT
    ApiBoundary.scan([File.join(root, "ui")], base: root).map(&.to_s).should eq([] of String)
  end

  it "ne parle au métier de l'extension, depuis ui/bulma, que par Teledec::Api (ADR-005 D4)" do
    allowed = %w[Api Ui CODE VERSION]
    leaks = source_files("ui/**/*.cr").flat_map do |path|
      File.read_lines(path).each_with_index(1).flat_map do |line, number|
        ApiBoundary.strip_comment(line).scan(/(?<![\w:])Teledec::([A-Za-z_]\w*)/).compact_map do |match|
          "#{path.lchop(Teledec::SpecSupport::ROOT + "/")}:#{number} Teledec::#{match[1]}" unless allowed.includes?(match[1])
        end
      end
    end
    leaks.should be_empty
  end

  it "ne parle au cœur, depuis src/, que par Partiduo::Api (ADR-006 D3)" do
    leaks = source_files("src/**/*.cr").select do |path|
      File.read(path).matches?(/Partiduo::(Invoicing|Accounting|Cards|Core|Vat|Liberal|Micro|Auth)::/)
    end
    leaks.map(&.lchop(Teledec::SpecSupport::ROOT + "/")).should be_empty
  end

  it "ne journalise ni n'affiche la clé de l'API" do
    credentials = Teledec::Credentials.new("cabinet", "secret-tres-long", "sandbox")
    credentials.to_s.should_not contain("secret-tres-long")
    credentials.inspect.should_not contain("secret-tres-long")
  end

  it "n'utilise que des icônes de la planche de l'interface (ADR-005 D5)" do
    lucide = File.join(Teledec::SpecSupport::ROOT, "lib", "partiduo-ui-bulma", "icons", "lucide")
    known = Dir.glob(File.join(lucide, "*.svg")).map { |path| File.basename(path, ".svg") }
    known.should_not be_empty
    used = source_files("ui/bulma/templates/**/*.html").flat_map do |path|
      File.read(path).scan(/_icon\.html" with name="([a-z0-9-]+)"/).map { |match| "#{path.lchop(Teledec::SpecSupport::ROOT + "/")} #{match[1]}" }
    end
    used.reject { |item| known.includes?(item.split(' ').last) }.should be_empty
  end
end
