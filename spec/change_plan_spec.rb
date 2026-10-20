# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Vxlan::ChangePlan do
  let(:change) { { "kind" => "svi_acl", "vlan" => 8, "vni" => 10008, "acl" => "protect", "direction" => "out", "entries" => [ { "sequence" => 10, "action" => "deny", "expression" => "ip any any" } ], "create_acl" => true, "previous_binding" => nil } }

  def target_config
    { "interfaces" => { "Vlan8" => { "acl_bindings" => {} } }, "vlan_vnis" => { "8" => 10008 }, "acls" => {} }
  end

  it "only binds an existing unassigned VLAN with matching gateway and complete L2 transport" do
    config = { "vlan_vnis" => { "8" => nil }, "interfaces" => { "Vlan8" => { "addresses" => [ "192.0.2.254/24" ], "vrf" => "tenant", "anycast" => true } },
      "nv_overlay_evpn" => true, "nve" => { "members" => { "10008" => { "associate_vrf" => false } } }, "evpn" => { "10008" => { "type" => "l2" } } }
    mapping = { "kind" => "vlan_vni_add", "vlan" => 8, "vni" => 10008, "vrf" => "tenant", "address" => "192.0.2.254/24" }
    before = Marshal.load(Marshal.dump(config))
    expect(described_class.build(mapping).eligible?(config)).to be(true)
    expect(described_class.build(mapping).satisfied?(config, before: before)).to be(false)
    config["vlan_vnis"]["8"] = 10009
    expect(described_class.build(mapping).eligible?(config)).to be(false)
    config["vlan_vnis"]["8"] = 10008
    expect(described_class.build(mapping).satisfied?(config, before: before)).to be(true)
    config["nve"]["members"]["10008"]["associate_vrf"] = true
    expect(described_class.build(mapping).satisfied?(config, before: before)).to be(false)
  end

  it "rejects ACL creation that activates another existing interface binding" do
    config = target_config
    config["interfaces"]["Ethernet1/1"] = { "acl_bindings" => { "in" => "protect" } }
    expect(described_class.build(change).eligible?(config)).to be(false)
  end

  it "rejects a mapping at execution time when another local SVI overlaps its gateway" do
    config = { "vlan_vnis" => { "8" => nil, "9" => 10009 }, "interfaces" => {
      "Vlan8" => { "addresses" => [ "192.0.2.254/24" ], "vrf" => "tenant", "anycast" => true },
      "Vlan9" => { "addresses" => [ "192.0.2.129/25" ], "vrf" => "tenant", "anycast" => true }
    }, "nve" => { "members" => { "10008" => { "associate_vrf" => false } } }, "evpn" => { "10008" => { "type" => "l2" } } }
    mapping = { "kind" => "vlan_vni_add", "vlan" => 8, "vni" => 10008, "vrf" => "tenant", "address" => "192.0.2.254/24" }
    before = Marshal.load(Marshal.dump(config))
    expect(described_class.build(mapping).eligible?(config)).to be(false)
    config["vlan_vnis"]["8"] = 10008
    expect(described_class.build(mapping).satisfied?(config, before: before)).to be(false)
  end

  it "requires a verified dependency snapshot and checks it again after configuration" do
    config = target_config
    change["entries"][0]["expression"] = "ip addrgroup admins any"
    expect(described_class.candidate(change, config: config)).to be_nil
    config["address_groups"] = { "admins" => [ "192.0.2.0/24" ] }
    change["address_groups"] = { "admins" => [ "192.0.2.0/24" ] }
    before = Marshal.load(Marshal.dump(config))
    expect(described_class.build(change).eligible?(config)).to be(true)
    config["acls"]["protect"] = change["entries"]
    config["interfaces"]["Vlan8"]["acl_bindings"]["out"] = "protect"
    config["address_groups"]["admins"] = [ "198.51.100.0/24" ]
    expect(described_class.build(change).satisfied?(config, before: before)).to be(false)
  end

  it "rejects an ACL change whose time range dependency is not modeled" do
    change["entries"][0]["expression"] = "ip any any time-range WINDOW"
    expect { described_class.build(change) }.to raise_error(ArgumentError)
    expect(described_class.candidate(change, config: target_config)).to be_nil
  end

  it "does not verify a new ACL when readback shows an additional affected interface" do
    config = target_config
    before = Marshal.load(Marshal.dump(config))
    expect(described_class.build(change).eligible?(config)).to be(true)
    config["acls"]["protect"] = change["entries"]
    config["interfaces"]["Vlan8"]["acl_bindings"]["out"] = "protect"
    expect(described_class.build(change).satisfied?(config, before: before)).to be(true)
    config["interfaces"]["Ethernet1/1"] = { "acl_bindings" => { "in" => "protect" } }
    expect(described_class.build(change).satisfied?(config, before: before)).to be(false)
  end

  it "rejects newline or command-separator injection in ACL expressions" do
    [ "ip any any\nend", "ip any any; reboot" ].each do |expression|
      change["entries"][0]["expression"] = expression
      expect { described_class.build(change) }.to raise_error(ArgumentError)
    end
  end

  it "does not accept a missing VNI, non-boolean creation flag, or duplicate ACL sequence" do
    [ change.merge("vni" => nil), change.merge("create_acl" => "false"), change.merge("entries" => change["entries"] * 2) ].each do |invalid|
      expect { described_class.build(invalid) }.to raise_error(ArgumentError)
    end
  end

  it "ignores ACL renumbering but preserves matching order" do
    entries = [ { "sequence" => 10, "action" => "deny", "expression" => "ip any 192.0.2.0/24" }, { "sequence" => 20, "action" => "permit", "expression" => "ip any any" } ]
    renumbered = entries.each_with_index.map { |entry, i| entry.merge("sequence" => (i + 1) * 100) }
    reversed = entries.reverse.each_with_index.map { |entry, i| entry.merge("sequence" => (i + 1) * 100) }
    expect(Vxlan::AclPolicy.rules(entries)).to eq(Vxlan::AclPolicy.rules(renumbered))
    expect(Vxlan::AclPolicy.rules(entries)).not_to eq(Vxlan::AclPolicy.rules(reversed))
  end
end
