# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Teledec::SpecSupport
private alias Api = Teledec::Api
private alias Books = PartiduoUi::Books

private def transmitted_liasse : Api::FilingView
  S.books
  Books.sale(Books.card("CUSTOMER", "Atelier Morel").code, "1000")
  S.connect
  filing = S.liasse
  Api.transmit(S.admin, filing.id).value!
end

private def token : String
  path = Api.settings(S.admin).callback_path
  URI::Params.parse(URI.parse(path).query.to_s)["token"]
end

describe "Rappels de TELEDEC (webhook)" do
  it "authentifie le rappel par le jeton de l'instance" do
    filing = transmitted_liasse
    S.teledec.acknowledge(S::LIASSE_ID)
    body = S.teledec.callback_body(S::LIASSE_ID)
    Api.callback(nil, body).should eq("unauthorized")
    Api.callback("faux", body).should eq("unauthorized")
    Api.settings(S.admin([Api::READ])).callback_path.should eq("")
    Api.filing(S.admin, filing.id).status.should eq("transmitted")
  end

  it "note l'accusé et joint son PDF, une seule fois pour une même déclaration" do
    filing = transmitted_liasse
    S.teledec.acknowledge(S::LIASSE_ID)
    body = S.teledec.callback_body(S::LIASSE_ID)
    Api.callback(token, body).should eq("ok")
    done = Api.filing(S.admin, filing.id)
    done.status.should eq("acknowledged")
    done.declaration_id.should eq(S.teledec.deposits[S::LIASSE_ID].declaration_id.to_s)
    receipt = Api.receipt_file(S.admin, filing.id) || raise "accusé absent"
    String.new(receipt.content).should start_with("%PDF-1.4")
    # Rappel rejoué : rien ne change.
    Api.callback(token, body).should eq("ok")
    Api.events(S.admin, filing.id).map(&.status).should eq(%w[prepared transmitted acknowledged])
    Api.filing(S.admin, filing.id).receipt_attachment_id.should eq(done.receipt_attachment_id)
  end

  it "note le rejet, suit un rappel intermédiaire et ignore une référence inconnue ou un corps illisible" do
    filing = transmitted_liasse
    sent = JSON.parse(S.teledec.callback_body(S::LIASSE_ID)).as_h
    sent["status"] = JSON::Any.new("Sent")
    sent["formulairesStatus"] = JSON::Any.new("Sent")
    Api.callback(token, sent.to_json).should eq("ok")
    Api.filing(S.admin, filing.id).remote_status.should eq("sent")
    S.teledec.reject(S::LIASSE_ID, "Balance déséquilibrée")
    Api.callback(token, S.teledec.callback_body(S::LIASSE_ID)).should eq("ok")
    rejected = Api.filing(S.admin, filing.id)
    rejected.status.should eq("rejected")
    rejected.rejection_reason.should eq("Balance déséquilibrée")
    Api.callback(token, %({"reference": "inconnue", "declarationId": 1, "status": "OK"})).should eq("ignored")
    Api.callback(token, "pas du JSON").should eq("invalid")
  end

  it "est servi hors de /ext/, sans session ni jeton CSRF" do
    filing = transmitted_liasse
    S.teledec.acknowledge(S::LIASSE_ID)
    body = S.teledec.callback_body(S::LIASSE_ID)
    Marten.routes.reverse("teledec_callback").should eq("/hooks/TELEDEC/callback")
    client = Marten::Spec::Client.new
    client.post("/hooks/TELEDEC/callback", content_type: "application/json", data: body).status.should eq(401)
    basic = {"Authorization" => "Basic #{Base64.strict_encode("teledec:#{token}")}"}
    client.post("/hooks/TELEDEC/callback", content_type: "application/json", data: body, headers: basic).status.should eq(200)
    Api.filing(S.admin, filing.id).status.should eq("acknowledged")
    bearer = {"Authorization" => "Bearer #{token}"}
    client.post("/hooks/TELEDEC/callback", content_type: "application/json", data: body, headers: bearer).status.should eq(200)
    client.post("/hooks/TELEDEC/callback", query_params: {"token" => token}, content_type: "application/json", data: "{")
      .status.should eq(400)
    Partiduo::Api::Modules.deactivate(S::SYSTEM, Teledec::CODE).value!
    client.post("/hooks/TELEDEC/callback", content_type: "application/json", data: body, headers: bearer).status.should eq(404)
    client.get("/hooks/TELEDEC/callback").status.should eq(405)
  end
end
