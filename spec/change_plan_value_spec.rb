# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "Immutable business changes" do
  let(:change) do
    { "kind" => "svi_acl", "vlan" => 8, "vni" => 10008, "acl" => "protect", "direction" => "out",
      "entries" => [ { "sequence" => 10, "action" => "deny", "expression" => "ip any any" } ],
      "create_acl" => true, "previous_binding" => nil }
  end
  let(:config) { { "interfaces" => { "Vlan8" => { "acl_bindings" => {} } }, "vlan_vnis" => { "8" => 10008 }, "acls" => {} } }

  it "keeps confirmed commands and parameters independent of caller mutations" do
    plan = Vxlan::ChangePlan.build(change)
    change["acl"] = "different"
    change["entries"].first["expression"] = "ip any 192.0.2.0/24"
    expect(plan.commands).to eq([ "configure terminal", "ip access-list protect", "  10 deny ip any any", "exit",
      "interface Vlan8", "  ip access-group protect out", "end" ])
    expect(plan.to_h["acl"]).to eq("protect")
    expect(plan.eligible?(config)).to be(true)
    expect { plan.commands << "reboot" }.to raise_error(FrozenError)
    expect { plan.commands.first.replace("reboot") }.to raise_error(FrozenError)
    expect { plan.to_h["entries"].first["action"] = "permit" }.to raise_error(FrozenError)
    expect { plan.rollback.clear }.to raise_error(FrozenError)
  end

  it "rejects malformed or arbitrary changes when crossing the construction boundary" do
    [ nil, [], change.merge("kind" => "arbitrary"), change.merge("commands" => [ "reboot" ]),
      change.merge("entries" => [ nil ]), change.merge("vlan" => "8"), change.merge("create_acl" => "false") ].each do |invalid|
      expect { Vxlan::ChangePlan.build(invalid) }.to raise_error(ArgumentError)
    end
  end

  it "keeps an incomplete recommendation unplannable" do
    expect(Vxlan::ChangePlan.candidate(change.merge("vlan" => nil), config: config)).to be_nil
    expect(Vxlan::ChangePlan.candidate(change, config: {})).to be_nil
    expect(Vxlan::ChangePlan.candidate(change, config: config).commands.last).to eq("end")
  end

  it "requires an eligible starting state as well as a correct readback target" do
    change["create_acl"] = false
    config["acls"] = { "protect" => change["entries"], "other" => change["entries"] }
    after = Marshal.load(Marshal.dump(config))
    after["interfaces"]["Vlan8"]["acl_bindings"]["out"] = "protect"
    plan = Vxlan::ChangePlan.build(change)
    expect(plan.satisfied?(after, before: config)).to be(true)
    config["interfaces"]["Vlan8"]["acl_bindings"]["out"] = "other"
    expect(plan.eligible?(config)).to be(false)
    expect(plan.satisfied?(after, before: config)).to be(false)
  end
end
