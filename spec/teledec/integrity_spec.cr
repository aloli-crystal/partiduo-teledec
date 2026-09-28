# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Teledec::SpecSupport
private alias Api = Teledec::Api

# Instruction SQL brute : message d'erreur de PostgreSQL, `nil` si elle passe.
private def sql_error(sql : String, *args) : String?
  Marten::DB::Connection.default.open(&.exec(sql, *args))
  nil
rescue ex : PQ::PQError
  ex.message
end

private def sql_int(sql : String, *args) : Int64
  Marten::DB::Connection.default.open(&.scalar(sql, *args)).as(Int).to_i64
end

# Dépôt inséré directement en base (contournant le contrat).
private def insert_filing(key : String, kind : String = "liasse", status : String = "prepared", remote_id : String = "",
                          manual : Bool = false, reason : String = "", from : String = "2026-01-01",
                          to : String = "2026-12-31", receipt : Int64? = nil) : String?
  sql_error(<<-SQL, key, kind, status, remote_id, manual, reason, from, to, receipt)
    INSERT INTO teledec_filing (key, kind, forms, year, number, period_from, period_to, status, payload, fingerprint,
      controls, remote_id, rejection_reason, last_error, manual, receipt_attachment_id, prepared_at, created_at, updated_at)
    VALUES ($1, $2, '2065', 2026, 0, $7::date, $8::date, $3, '{}', 'x', '[]', $4, $6, '', $5, $9, now(), now(), now())
    SQL
end

private def filing_id(key : String) : Int64
  sql_int("SELECT id FROM teledec_filing WHERE key = $1", key)
end

private def insert_settings(key : String = "default", tax : String = "is_rsi", vat : String = "ca12", env : String = "sandbox",
                            threshold : String = "1200") : String?
  sql_error(<<-SQL, key, tax, vat, env, threshold)
    INSERT INTO teledec_settings (key, tax_system, vat_system, greffe, das2_accounts, das2_threshold, env, login, api_key,
      created_at, updated_at)
    VALUES ($1, $2, $3, false, '', $5::numeric, $4, '', '', now(), now())
    SQL
end

describe "Intégrité des tables teledec_* en base (migration 0001)" do
  it "contrôle les sortes, statuts et périodes d'un dépôt, et l'unicité de sa clé" do
    insert_filing("liasse:1").should be_nil
    insert_filing("liasse:1").to_s.should contain("teledec_filing_key_key")
    insert_filing("bilan:1", kind: "bilan").to_s.should contain("teledec_filing_kind_check")
    insert_filing("liasse:2", status: "sent", manual: true).to_s.should contain("teledec_filing_status_check")
    insert_filing("liasse:3", from: "2026-12-31", to: "2026-01-01").to_s.should contain("teledec_filing_period_check")
    insert_filing("liasse:4", from: "2026-06-30", to: "2026-06-30").should be_nil
  end

  it "exige l'identifiant TELEDEC d'un dépôt transmis (sauf dépôt noté à la main) et le motif d'un rejet" do
    insert_filing("liasse:1", status: "transmitted").to_s.should contain("teledec_filing_remote_check")
    insert_filing("liasse:1", status: "acknowledged").to_s.should contain("teledec_filing_remote_check")
    insert_filing("liasse:1", status: "transmitted", manual: true).should be_nil
    insert_filing("liasse:2", status: "transmitted", remote_id: "TD-1").should be_nil
    insert_filing("liasse:3", status: "rejected", remote_id: "TD-2").to_s.should contain("teledec_filing_rejected_check")
    insert_filing("liasse:3", status: "rejected", remote_id: "TD-2", reason: "SIREN inconnu").should be_nil
  end

  it "rattache l'accusé à une pièce jointe existante du socle" do
    insert_filing("liasse:1", receipt: 987_654_i64).to_s.should contain("teledec_filing_receipt_fk")
  end

  it "rattache l'exercice et les auteurs aux tables du socle (exercice cité non supprimable, auteur supprimé effacé)" do
    S.books
    PartiduoUi::Books.sale(PartiduoUi::Books.card("CUSTOMER", "Atelier Morel").code, "1000")
    filing = S.liasse
    sql_error("UPDATE teledec_filing SET fiscal_year_id = 987654 WHERE id = $1", filing.id).to_s.should contain("teledec_filing_fiscal_year_fk")
    sql_error("UPDATE teledec_filing SET prepared_by_id = 987654 WHERE id = $1", filing.id).to_s.should contain("teledec_filing_prepared_by_fk")
    sql_error("UPDATE teledec_filing SET transmitted_by_id = 987654 WHERE id = $1", filing.id).to_s.should contain("teledec_filing_transmitted_by_fk")
    sql_error("UPDATE teledec_filing_event SET user_id = 987654 WHERE filing_id = $1", filing.id).to_s.should contain("teledec_filing_event_user_fk")
    sql_error("UPDATE teledec_settings SET updated_by_id = 987654").to_s.should contain("teledec_settings_updated_by_fk")
    sql_error("DELETE FROM core_fiscal_year WHERE id = $1", S.fiscal_year_id).to_s.should contain("teledec_filing_fiscal_year_fk")
    user_id = S.admin.user_id || raise "utilisateur absent"
    sql_int("SELECT count(*) FROM teledec_filing WHERE prepared_by_id = $1", user_id).should eq(1)
  end

  it "rend intangible le document d'un dépôt transmis, et définitif le statut d'un dépôt accusé (déclencheur)" do
    insert_filing("liasse:1").should be_nil
    id = filing_id("liasse:1")
    # Préparé : le document se remplace, le dépôt se supprime.
    sql_error("UPDATE teledec_filing SET payload = '{\"a\":1}' WHERE id = $1", id).should be_nil
    sql_error("DELETE FROM teledec_filing WHERE id = $1", id).should be_nil

    insert_filing("liasse:2", status: "transmitted", remote_id: "TD-1").should be_nil
    id = filing_id("liasse:2")
    %w[payload fingerprint key kind].each do |column|
      value = column == "kind" ? "greffe" : "autre"
      sql_error("UPDATE teledec_filing SET #{column} = $1 WHERE id = $2", value, id).to_s.should contain("intangible")
    end
    sql_error("DELETE FROM teledec_filing WHERE id = $1", id).to_s.should contain("intangible")
    # Le statut d'un dépôt transmis évolue (accusé, rejet) sans toucher au document.
    sql_error("UPDATE teledec_filing SET status = 'acknowledged' WHERE id = $1", id).should be_nil
    sql_error("UPDATE teledec_filing SET status = 'rejected', rejection_reason = 'x' WHERE id = $1", id)
      .to_s.should contain("définitif")
    sql_error("UPDATE teledec_filing SET status = 'prepared' WHERE id = $1", id).to_s.should contain("définitif")
    sql_error("DELETE FROM teledec_filing WHERE id = $1", id).to_s.should contain("intangible")
    # Rejeté : le dépôt se prépare de nouveau (document remplacé).
    insert_filing("liasse:3", status: "rejected", remote_id: "TD-2", reason: "motif").should be_nil
    sql_error("UPDATE teledec_filing SET status = 'prepared', payload = '{}' WHERE key = 'liasse:3'").should be_nil
  end

  it "contrôle l'historique d'un dépôt et le supprime avec lui" do
    insert_filing("liasse:1").should be_nil
    id = filing_id("liasse:1")
    event = "INSERT INTO teledec_filing_event (filing_id, status, detail, created_at) VALUES ($1, $2, '', now())"
    sql_error(event, id, "prepared").should be_nil
    sql_error(event, id, "error").should be_nil
    sql_error(event, id, "lost").to_s.should contain("teledec_filing_event_status_check")
    sql_error(event, 987_654_i64, "prepared").to_s.should contain("teledec_filing_event_filing_fk")
    sql_error("DELETE FROM teledec_filing WHERE id = $1", id).should be_nil
    sql_int("SELECT count(*) FROM teledec_filing_event WHERE filing_id = $1", id).should eq(0)
  end

  it "garde une seule ligne de paramètres aux valeurs contrôlées" do
    insert_settings("second").to_s.should contain("teledec_settings_key_check")
    insert_settings(tax: "lmnp").to_s.should contain("teledec_settings_tax_system_check")
    insert_settings(vat: "ca3").to_s.should contain("teledec_settings_vat_system_check")
    insert_settings(env: "lune").to_s.should contain("teledec_settings_env_check")
    insert_settings(threshold: "-1").to_s.should contain("teledec_settings_threshold_check")
    insert_settings(tax: "", vat: "").should be_nil
    insert_settings.to_s.should contain("teledec_settings_key_key")
  end

  it "interdit de supprimer la pièce jointe qui porte l'accusé d'un dépôt" do
    S.books
    PartiduoUi::Books.sale(PartiduoUi::Books.card("CUSTOMER", "Atelier Morel").code, "1000")
    S.connect
    filing = S.liasse
    Api.transmit(S.admin, filing.id).value!
    S.teledec.acknowledge("TD-000001")
    receipt_id = Api.refresh(S.admin, filing.id).value!.receipt_attachment_id || raise "accusé absent"
    sql_error("DELETE FROM core_attachment WHERE id = $1", receipt_id).to_s.should contain("teledec_filing_receipt_fk")
    # Le modèle passe par le même déclencheur que le SQL brut.
    expect_raises(Exception, /intangible/) { Teledec::Filing.get!(id: filing.id).delete }
  end
end
