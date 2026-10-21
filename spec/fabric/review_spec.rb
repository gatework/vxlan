# frozen_string_literal: true

require_relative "../spec_helper"
require "json"

RSpec.describe "Fabric business consistency" do
  def leaf(host, acl: "protect", address: "192.0.2.254/24", vni: 10008)
    { "device" => { "host" => host, "name" => host }, "snapshot" => { "dimensions" => {
      "configuration" => { "status" => "complete", "records" => [ {
        "review_status" => "complete", "vlan_vnis" => { "8" => vni }, "interfaces" => { "Vlan8" => { "addresses" => address ? [ address ] : [], "vrf" => "tenant", "anycast" => true, "shutdown" => false, "mtu" => 9216, "acl_bindings" => acl ? { "out" => acl } : {} } },
        "acls" => { "protect" => [ { "sequence" => 10, "action" => "deny", "expression" => "ip any 192.0.2.0/24" }, { "sequence" => 20, "action" => "permit", "expression" => "ip any any" } ] },
        "nve" => { "interface" => "nve1", "members" => { vni.to_s => { "associate_vrf" => false, "replication" => "bgp" } } }, "vrfs" => {}, "nv_overlay_evpn" => true,
        "evpn" => { vni.to_s => { "type" => "l2", "route_targets" => [ { "direction" => "both", "target" => "auto" } ] } }, "anycast_mac" => "0011.0011.0011"
      } ] }
    } } }
  end

  def audit(*documents)
    Vxlan::Fabric::Review.new(documents, { "fabrics" => { "test" => { "leaves" => documents.map { |d| d["device"]["host"] } } } }).call
  end

  it "compares address groups only across referencing hosts and retains missing definitions in host order" do
    documents = %w[192.0.2.1 192.0.2.2 192.0.2.3].map { |host| leaf(host, acl: nil) }
    documents.each_with_index do |document, index|
      config = document["snapshot"]["dimensions"]["configuration"]["records"][0]
      expression = index == 2 ? "ip any any" : "ip addrgroup admins addrgroup admins"
      config["acls"]["protect"][0]["expression"] = expression
      config["address_groups"] = index == 1 ? {} : { "admins" => [ "192.0.2.0/24" ] }
    end

    findings = audit(*documents)[:findings].select { |entry| entry[:code] == "fabric_address_group" }

    expect(findings.size).to eq(1)
    expect(findings.first[:evidence]).to eq([
      { host: "192.0.2.1", value: [ "192.0.2.0/24" ] }, { host: "192.0.2.2", value: nil }
    ])
  end

  def gateway_leaves(count)
    [ leaf("192.0.2.1"), leaf("192.0.2.2", address: nil) ].each_with_index.map do |document, host_index|
      config = document["snapshot"]["dimensions"]["configuration"]["records"][0]
      svi = config["interfaces"].fetch("Vlan8")
      config["vlan_vnis"], config["interfaces"], config["nve"]["members"], config["evpn"] = {}, {}, {}, {}
      count.times do |index|
        vlan, vni = (index + 1).to_s, 10_001 + index
        config["vlan_vnis"][vlan] = vni
        addresses = host_index.zero? ? [ "10.#{index / 256}.#{index % 256}.254/24" ] : []
        config["interfaces"]["Vlan#{vlan}"] = svi.merge("addresses" => addresses)
        config["nve"]["members"][vni.to_s] = { "associate_vrf" => false, "replication" => "bgp" }
        config["evpn"][vni.to_s] = { "type" => "l2", "route_targets" => [ { "direction" => "both", "target" => "auto" } ] }
      end
      document
    end
  end

  it "rebuilds policy facts for each review without retaining a previous call's baseline" do
    a, b = leaf("192.0.2.1"), leaf("192.0.2.2")
    reviewer = Vxlan::Fabric::Review.new([ a, b ], { "fabrics" => { "test" => { "leaves" => %w[192.0.2.1 192.0.2.2] } } })
    expect(reviewer.call[:findings]).to be_empty
    b["snapshot"]["dimensions"]["configuration"]["records"][0]["acls"]["protect"][0]["action"] = "permit"
    expect(reviewer.call[:findings]).to include(include(code: "fabric_acl_content"))
  end

  it "compares local VLAN mappings for a shared L2-only VNI without gateways" do
    a, b = leaf("192.0.2.1"), leaf("192.0.2.2")
    [ a, b ].each { |d| d["snapshot"]["dimensions"]["configuration"]["records"][0]["interfaces"] = {} }
    b["snapshot"]["dimensions"]["configuration"]["records"][0]["vlan_vnis"] = { "9" => 10008 }
    expect(audit(a, b)[:findings]).to include(include(code: "fabric_vlan_mapping", vni: 10008))
  end

  it "reports ambiguous VLAN mappings even when only one leaf deploys the VNI" do
    a, b = leaf("192.0.2.1"), leaf("192.0.2.2", vni: 10009, address: "198.51.100.254/24")
    a["snapshot"]["dimensions"]["configuration"]["records"][0]["vlan_vnis"]["9"] = 10008
    expect(audit(a, b)[:findings]).to include(include(code: "fabric_vlan_mapping_ambiguous", vni: 10008))
  end

  it "reports overlapping different prefixes on different VNIs without proposing a gateway change" do
    result = audit(leaf("192.0.2.1"), leaf("192.0.2.2", vni: 10009, address: "192.0.2.129/25"))
    expect(result[:findings]).to include(include(code: "fabric_subnet_vni_conflict"))
    expect(result[:device_items].values.flatten).to be_empty
  end

  it "aggregates repeated anycast subnet evidence into one conflict" do
    result = audit(leaf("192.0.2.1"), leaf("192.0.2.2"), leaf("192.0.2.3", vni: 10009), leaf("192.0.2.4", vni: 10009))
    conflicts = result[:findings].select { |finding| finding[:code] == "fabric_subnet_vni_conflict" }
    expect(conflicts.size).to eq(1)
    expect(conflicts.first[:evidence].map { |row| row[:host] }).to contain_exactly("192.0.2.1", "192.0.2.2", "192.0.2.3", "192.0.2.4")
  end

  it "keeps same-VNI overlap and separate VRFs out of cross-VNI subnet conflicts" do
    a = leaf("192.0.2.1")
    b = leaf("192.0.2.2", address: "192.0.2.129/25")
    c = leaf("192.0.2.3", vni: 10009)
    c["snapshot"]["dimensions"]["configuration"]["records"][0]["interfaces"]["Vlan8"]["vrf"] = "other"
    expect(audit(a, b, c)[:findings]).not_to include(include(code: "fabric_subnet_vni_conflict"))
  end

  it "does not derive changes from partial or missing configuration review evidence" do
    [ "partial", nil ].each do |status|
      a, b = leaf("192.0.2.1"), leaf("192.0.2.2", acl: nil)
      a["snapshot"]["dimensions"]["configuration"]["records"][0]["review_status"] = status
      result = audit(a, b)
      expect(result[:findings]).to include(include(code: "fabric_evidence_incomplete"))
      expect(result[:device_items].values.flatten).to be_empty
    end
  end

  it "retains differing ACL rules when both definitions have unknown dependencies" do
    a, b = leaf("192.0.2.1", acl: nil), leaf("192.0.2.2", acl: nil)
    [ a, b ].each do |d|
      d["snapshot"]["dimensions"]["configuration"]["records"][0]["acls"]["protect"][0]["expression"] = "ip addrgroup unknown any"
    end
    b["snapshot"]["dimensions"]["configuration"]["records"][0]["acls"]["protect"][0]["action"] = "permit"
    result = audit(a, b)
    expect(result[:findings]).to include(include(code: "fabric_acl_content"), include(code: "fabric_acl_dependency"))
    expect(result[:device_items].values.flatten).to be_empty
  end

  it "reports unmodeled ACL time ranges even when rule text matches and blocks missing bindings" do
    documents = [ leaf("192.0.2.1"), leaf("192.0.2.2") ]
    documents.zip(%w[weekdays weekend]).each do |document, period|
      parsed = Vxlan::Config.new.parse(<<~CONFIG, complete: true)
        hostname LEAF
        ip access-list protect
          10 permit ip any any time-range WINDOW
        time-range WINDOW
          periodic #{period} 09:00:00 to 17:00:00
      CONFIG
      expect(parsed).to be_complete
      document["snapshot"]["dimensions"]["configuration"]["records"][0]["acls"] = JSON.parse(JSON.generate(parsed.records.first[:acls]))
    end
    expect(audit(*documents)[:findings]).to include(include(code: "fabric_acl_dependency"))

    documents.last["snapshot"]["dimensions"]["configuration"]["records"][0]["interfaces"]["Vlan8"]["acl_bindings"].clear
    result = audit(*documents)
    expect(result[:findings]).to include(include(code: "fabric_acl_dependency"))
    expect(result[:device_items]["192.0.2.2"]).to include(include(code: "fabric_acl_binding", status: "blocked", commands: []))
    expect(result[:device_items].values.flatten).not_to include(include(status: "candidate"))
  end

  it "reports collected devices outside the declared Fabric coverage" do
    docs = [ leaf("192.0.2.1"), leaf("192.0.2.2"), leaf("192.0.2.3") ]
    result = Vxlan::Fabric::Review.new(docs, { "fabrics" => { "test" => { "leaves" => %w[192.0.2.1 192.0.2.2] } } }).call
    expect(result[:inventory][:unassigned]).to eq([ "192.0.2.3" ])
    expect(result[:findings]).to include(include(code: "fabric_scope_unassigned"))
  end

  it "compares borders separately and identifies service configuration on a declared spine" do
    docs = [ leaf("192.0.2.1"), leaf("192.0.2.2"), leaf("192.0.2.3", acl: nil), leaf("192.0.2.4", acl: nil), leaf("192.0.2.5") ]
    policy = { "fabrics" => { "test" => { "leaves" => %w[192.0.2.1 192.0.2.2], "borders" => %w[192.0.2.3 192.0.2.4], "spines" => %w[192.0.2.5] } } }
    result = Vxlan::Fabric::Review.new(docs, policy).call
    expect(result[:findings]).not_to include(include(code: "fabric_acl_binding"))
    expect(result[:device_items]["192.0.2.5"]).to include(include(code: "fabric_role_conflict", status: "blocked", commands: []))
    expect(result[:inventory][:unassigned]).to be_empty
  end

  it "keeps a partially deployed VNI visible even when its local VLAN mapping is missing" do
    a, b = leaf("192.0.2.1"), leaf("192.0.2.2", acl: nil)
    b["snapshot"]["dimensions"]["configuration"]["records"][0]["vlan_vnis"] = {}
    result = audit(a, b)
    expect(result[:coverage]).to include(include(vni: 10008, deployed: %w[192.0.2.1 192.0.2.2], incomplete: [ "192.0.2.2" ]))
    expect(result[:findings]).to include(include(code: "fabric_service_incomplete"))
    expect(result[:device_items].values.flatten.select { |item| item[:status] == "candidate" }).to be_empty
  end

  it "proposes an existing unmapped VLAN only when its SVI and transport match the deployed peer business" do
    a, b = leaf("192.0.2.1"), leaf("192.0.2.2")
    b["snapshot"]["dimensions"]["configuration"]["records"][0]["vlan_vnis"]["8"] = nil
    item = audit(a, b)[:device_items]["192.0.2.2"].find { |advice| advice[:code] == "fabric_vlan_mapping_missing" }
    expect(item).to include(status: "candidate", commands: [ "configure terminal", "vlan 8", "  vn-segment 10008", "end" ])
    expect(item[:change]).to include("kind" => "vlan_vni_add", "vlan" => 8, "vni" => 10008)
  end

  it "does not infer a VLAN mapping from matching numbers when gateway facts disagree" do
    a, b = leaf("192.0.2.1"), leaf("192.0.2.2", address: "198.51.100.254/24")
    b["snapshot"]["dimensions"]["configuration"]["records"][0]["vlan_vnis"]["8"] = nil
    result = audit(a, b)
    expect(result[:device_items]["192.0.2.2"]).to include(include(code: "fabric_vlan_mapping_missing", status: "blocked", commands: []))
  end

  it "does not ignore an incomplete conflicting peer when inferring a missing mapping" do
    a, b, c = leaf("192.0.2.1"), leaf("192.0.2.2"), leaf("192.0.2.3", address: "198.51.100.254/24")
    b["snapshot"]["dimensions"]["configuration"]["records"][0]["vlan_vnis"]["8"] = nil
    c["snapshot"]["dimensions"]["configuration"]["records"][0]["nve"]["members"] = {}
    expect(audit(a, b, c)[:device_items]["192.0.2.2"]).to include(include(code: "fabric_vlan_mapping_missing", status: "blocked", commands: []))
  end

  it "does not activate an overlapping gateway on another VNI when adding a mapping" do
    a, b = leaf("192.0.2.1"), leaf("192.0.2.2")
    config = b["snapshot"]["dimensions"]["configuration"]["records"][0]
    config["vlan_vnis"] = { "8" => nil, "9" => 10009 }
    config["interfaces"]["Vlan9"] = config["interfaces"]["Vlan8"].dup
    expect(audit(a, b)[:device_items]["192.0.2.2"]).to include(include(code: "fabric_vlan_mapping_missing", status: "blocked", commands: []))
  end

  it "detects transport differences even for an L2-only service with no gateway" do
    a, b = leaf("192.0.2.1", address: nil), leaf("192.0.2.2", address: nil)
    [ a, b ].each { |d| d["snapshot"]["dimensions"]["configuration"]["records"][0]["interfaces"] = {} }
    b["snapshot"]["dimensions"]["configuration"]["records"][0]["nve"]["members"]["10008"] = { "associate_vrf" => false, "multicast_group" => "239.1.1.1" }
    expect(audit(a, b)[:findings]).to include(include(code: "fabric_replication"))
  end

  it "checks cross-device subnet conflicts before connecting an unmapped VLAN" do
    a, b, c = leaf("192.0.2.1"), leaf("192.0.2.2"), leaf("192.0.2.3", vni: 10009)
    b["snapshot"]["dimensions"]["configuration"]["records"][0]["vlan_vnis"]["8"] = nil
    expect(audit(a, b, c)[:device_items]["192.0.2.2"]).to include(include(code: "fabric_vlan_mapping_missing", status: "blocked", commands: []))
  end

  it "compares inherited multicast groups before connecting an unmapped VLAN" do
    a, b = leaf("192.0.2.1"), leaf("192.0.2.2")
    [ a, b ].each_with_index do |document, index|
      nve = document["snapshot"]["dimensions"]["configuration"]["records"][0]["nve"]
      nve["members"]["10008"] = { "associate_vrf" => false }
      nve["multicast_group"] = "239.1.1.#{index + 1}"
    end
    b["snapshot"]["dimensions"]["configuration"]["records"][0]["vlan_vnis"]["8"] = nil
    result = audit(a, b)
    expect(result[:findings]).to include(include(code: "fabric_replication"))
    expect(result[:device_items]["192.0.2.2"]).to include(include(code: "fabric_vlan_mapping_missing", status: "blocked", commands: []))
  end

  it "treats both directions as equivalent to separate import and export RT declarations" do
    a, b = leaf("192.0.2.1"), leaf("192.0.2.2")
    b["snapshot"]["dimensions"]["configuration"]["records"][0]["evpn"]["10008"]["route_targets"] = %w[import export].map { |direction| { "direction" => direction, "target" => "auto" } }
    expect(audit(a, b)[:findings]).not_to include(include(code: "fabric_route_targets"))
  end

  it "blocks otherwise valid ACL additions while the service route targets disagree" do
    a, b = leaf("192.0.2.1"), leaf("192.0.2.2", acl: nil)
    b["snapshot"]["dimensions"]["configuration"]["records"][0]["evpn"]["10008"]["route_targets"] = [ { "direction" => "both", "target" => "65000:999" } ]
    result = audit(a, b)
    expect(result[:findings]).to include(include(code: "fabric_route_targets"))
    expect(result[:device_items]["192.0.2.2"]).to include(include(code: "fabric_acl_binding", status: "blocked", commands: []))
  end

  it "blocks otherwise valid ACL additions when tenant route targets disagree" do
    a, b = leaf("192.0.2.1"), leaf("192.0.2.2", acl: nil)
    [ a, b ].each_with_index do |document, index|
      document["snapshot"]["dimensions"]["configuration"]["records"][0]["vrfs"] = { "tenant" => { "vni" => 20000, "route_targets" => [ { "direction" => "both", "target" => "65000:#{index}" } ] } }
    end
    result = audit(a, b)
    expect(result[:findings]).to include(include(code: "fabric_tenant_routing"))
    expect(result[:device_items]["192.0.2.2"]).to include(include(code: "fabric_acl_binding", status: "blocked", commands: []))
  end

  it "blocks equal ACL text whose referenced address groups have different members" do
    a, b, c = leaf("192.0.2.1"), leaf("192.0.2.2"), leaf("192.0.2.3", acl: nil)
    [ a, b, c ].each_with_index do |document, index|
      config = document["snapshot"]["dimensions"]["configuration"]["records"][0]
      config["acls"]["protect"][0]["expression"] = "ip addrgroup admins any"
      config["address_groups"] = { "admins" => [ index == 1 ? "198.51.100.0/24" : "192.0.2.0/24" ] }
    end
    result = audit(a, b, c)
    expect(result[:findings]).to include(include(code: "fabric_acl_content"))
    expect(result[:device_items]["192.0.2.3"]).to include(include(status: "blocked", commands: []))
  end

  it "requires target dependencies even when the ACL definition itself will be created" do
    a, b = leaf("192.0.2.1"), leaf("192.0.2.2", acl: nil)
    source = a["snapshot"]["dimensions"]["configuration"]["records"][0]
    source["acls"]["protect"][0]["expression"] = "ip addrgroup admins any"
    source["address_groups"] = { "admins" => [ "192.0.2.0/24" ] }
    b["snapshot"]["dimensions"]["configuration"]["records"][0]["acls"] = {}
    expect(audit(a, b)[:device_items]["192.0.2.2"]).to include(include(status: "blocked", commands: []))
  end

  it "still proposes a missing ACL binding when all referenced group members agree" do
    a, b = leaf("192.0.2.1"), leaf("192.0.2.2", acl: nil)
    [ a, b ].each do |document|
      config = document["snapshot"]["dimensions"]["configuration"]["records"][0]
      config["acls"]["protect"][0]["expression"] = "ip addrgroup admins any"
      config["address_groups"] = { "admins" => [ "192.0.2.0/24" ] }
    end
    item = audit(a, b)[:device_items]["192.0.2.2"].first
    expect(item).to include(status: "candidate")
    expect(item[:change]["address_groups"]).to eq("admins" => [ "192.0.2.0/24" ])
  end

  it "still proposes a unique missing gateway when the common service context agrees" do
    result = audit(leaf("192.0.2.1"), leaf("192.0.2.2", address: nil))
    expect(result[:device_items]["192.0.2.2"]).to include(include(code: "fabric_gateway", status: "candidate", commands: include("  ip address 192.0.2.254/24")))
  end

  it "does not create a shared ACL through a single SVI change" do
    a, b = leaf("192.0.2.1"), leaf("192.0.2.2")
    config = b["snapshot"]["dimensions"]["configuration"]["records"][0]
    config["acls"] = {}
    config["interfaces"]["Vlan9"] = { "acl_bindings" => { "in" => "protect" } }
    result = audit(a, b)
    expect(result[:device_items]["192.0.2.2"]).to include(include(status: "blocked", commands: [], blockers: include(a_string_including("Vlan9"))))
  end

  it "does not transplant a gateway from another VRF" do
    a, b = leaf("192.0.2.1"), leaf("192.0.2.2", address: nil)
    b["snapshot"]["dimensions"]["configuration"]["records"][0]["interfaces"]["Vlan8"]["vrf"] = "other"
    expect(audit(a, b)[:device_items]["192.0.2.2"]).to include(include(code: "fabric_gateway", status: "blocked", commands: []))
  end

  it "preserves a minority ACL instead of recommending removal by majority vote" do
    result = audit(leaf("192.0.2.1"), leaf("192.0.2.2", acl: nil), leaf("192.0.2.3", acl: nil))
    items = result[:device_items].fetch("192.0.2.2")
    change = items.find { |item| item[:code] == "fabric_acl_binding" }
    expect(change).to include(status: "candidate")
    expect(change[:change]).to include("kind" => "svi_acl", "acl" => "protect", "direction" => "out")
    expect(result[:device_items].fetch("192.0.2.1", []).flat_map { |item| item[:commands] }).to be_empty
  end

  it "detects different ordered content even when ACL names and bindings match" do
    a, b = leaf("192.0.2.1"), leaf("192.0.2.2")
    b["snapshot"]["dimensions"]["configuration"]["records"][0]["acls"]["protect"][0]["action"] = "permit"
    result = audit(a, b)
    expect(result[:findings]).to include(include(code: "fabric_acl_content"))
    expect(result[:device_items].values.flatten.flat_map { |item| item[:commands] }).to be_empty
  end

  it "does not distribute a policy when an unbound same-name definition disagrees" do
    a, b, c = leaf("192.0.2.1"), leaf("192.0.2.2", acl: nil), leaf("192.0.2.3", acl: nil)
    b["snapshot"]["dimensions"]["configuration"]["records"][0]["acls"]["protect"][0]["action"] = "permit"
    result = audit(a, b, c)
    expect(result[:device_items]["192.0.2.3"]).to include(include(code: "fabric_acl_binding", status: "blocked", commands: []))
  end

  it "identifies an already attached but undefined ACL and proposes its missing definition" do
    a, b = leaf("192.0.2.1"), leaf("192.0.2.2")
    b["snapshot"]["dimensions"]["configuration"]["records"][0]["acls"] = {}
    result = audit(a, b)
    expect(result[:findings]).to include(include(code: "fabric_acl_undefined"))
    expect(result[:device_items]["192.0.2.2"].first[:change]).to include("create_acl" => true, "previous_binding" => "protect")
  end

  it "blocks adding a gateway already assigned to another VNI in the same VRF" do
    a, b = leaf("192.0.2.1"), leaf("192.0.2.2", address: nil)
    config = b["snapshot"]["dimensions"]["configuration"]["records"][0]
    config["vlan_vnis"]["1208"] = 11208
    config["interfaces"]["Vlan1208"] = config["interfaces"]["Vlan8"].merge("addresses" => [ "192.0.2.254/24" ])
    result = audit(a, b)
    expect(result[:device_items]["192.0.2.2"]).to include(include(code: "fabric_gateway", status: "blocked", commands: []))
    expect(result[:findings]).to include(include(code: "fabric_subnet_vni_conflict"))
  end

  it "blocks adding a gateway when a different Leaf carries an overlapping subnet on another VNI" do
    result = audit(leaf("192.0.2.1"), leaf("192.0.2.2", address: nil), leaf("192.0.2.3", vni: 10009, address: "192.0.2.129/25"))
    expect(result[:device_items]["192.0.2.2"]).to include(include(code: "fabric_gateway", status: "blocked", commands: []))
  end

  it "retains containing networks and ordered duplicate address evidence when blocking a gateway" do
    a, b = leaf("192.0.2.1"), leaf("192.0.2.2", address: nil)
    config = b["snapshot"]["dimensions"]["configuration"]["records"][0]
    config["vlan_vnis"].merge!("9" => 10009, "10" => 10010)
    config["interfaces"]["Vlan9"] = { "vrf" => "tenant", "addresses" => [ "192.0.0.1/16" ] }
    config["interfaces"]["Vlan10"] = { "vrf" => "tenant", "addresses" => [ "192.0.2.129/25", "192.0.2.129/25" ] }
    item = audit(a, b)[:device_items]["192.0.2.2"].find { |entry| entry[:code] == "fabric_gateway" }
    expect(item).to include(status: "blocked", commands: [])
    expect(item[:evidence].select { |entry| entry[:interface] }.map { |entry| entry.slice(:interface, :vni, :value) }).to eq([
      { interface: "Vlan9", vni: 10009, value: [ "192.0.0.1/16" ] },
      { interface: "Vlan10", vni: 10010, value: [ "192.0.2.129/25", "192.0.2.129/25" ] }
    ])
  end

  it "keeps other VRFs and address families outside an IPv4 gateway conflict" do
    a, b = leaf("192.0.2.1"), leaf("192.0.2.2", address: nil)
    config = b["snapshot"]["dimensions"]["configuration"]["records"][0]
    config["interfaces"]["Vlan9"] = { "vrf" => "other", "addresses" => [ "192.0.2.129/25" ] }
    config["interfaces"]["Vlan10"] = { "vrf" => "tenant", "addresses" => [ "2001:db8::1/64" ] }
    expect(audit(a, b)[:device_items]["192.0.2.2"]).to include(include(code: "fabric_gateway", status: "candidate"))
  end

  it "rejects malformed relevant subnet evidence instead of authorizing a gateway" do
    a, b = leaf("192.0.2.1"), leaf("192.0.2.2", address: nil)
    b["snapshot"]["dimensions"]["configuration"]["records"][0]["interfaces"]["Vlan9"] = { "vrf" => "tenant", "addresses" => [ "invalid" ] }
    expect { audit(a, b) }.to raise_error(IPAddr::InvalidAddressError)
  end

  it "does not turn an unrelated VRF's malformed address into gateway conflict evidence" do
    a, b = leaf("192.0.2.1"), leaf("192.0.2.2", address: nil)
    b["snapshot"]["dimensions"]["configuration"]["records"][0]["interfaces"]["Vlan9"] = { "vrf" => "other", "addresses" => [ "invalid" ] }
    expect(audit(a, b)[:device_items]["192.0.2.2"]).to include(include(code: "fabric_gateway", status: "candidate"))
  end

  it "rebuilds subnet facts when the same reviewer receives changed configuration" do
    a, b = leaf("192.0.2.1"), leaf("192.0.2.2", address: nil)
    reviewer = Vxlan::Fabric::Review.new([ a, b ], { "fabrics" => { "test" => { "leaves" => %w[192.0.2.1 192.0.2.2] } } })
    expect(reviewer.call[:device_items]["192.0.2.2"]).to include(include(code: "fabric_gateway", status: "candidate"))
    b["snapshot"]["dimensions"]["configuration"]["records"][0]["interfaces"]["Vlan9"] = { "vrf" => "tenant", "addresses" => [ "192.0.2.129/25" ] }
    expect(reviewer.call[:device_items]["192.0.2.2"]).to include(include(code: "fabric_gateway", status: "blocked", commands: []))
  end

  it "reviews growing gateway sets without quadratic allocation growth" do
    audit(*gateway_leaves(8))
    allocations = [ 128, 512 ].map do |count|
      documents = gateway_leaves(count)
      GC.start
      before = GC.stat(:total_allocated_objects)
      result = audit(*documents)
      allocated = GC.stat(:total_allocated_objects) - before
      expect(result[:device_items]["192.0.2.2"].count { |item| item[:status] == "candidate" }).to eq(count)
      allocated
    end
    expect(allocations.last).to be < allocations.first * 6
  end

  it "does not treat different deployed services as missing configuration" do
    result = audit(leaf("192.0.2.1"), leaf("192.0.2.2", vni: 10009, address: "198.51.100.254/24"))
    expect(result[:findings]).to be_empty
  end

  it "does not report missing address groups on leaves that do not reference them" do
    a, b = leaf("192.0.2.1"), leaf("192.0.2.2", vni: 10009, address: "198.51.100.254/24")
    config = a["snapshot"]["dimensions"]["configuration"]["records"][0]
    config["acls"]["protect"][0]["expression"] = "ip addrgroup admins any"
    config["address_groups"] = { "admins" => [ "192.0.2.0/24" ] }
    expect(audit(a, b)[:findings]).not_to include(include(code: "fabric_address_group"))
  end

  it "does not generate cross-device changes from an incomplete comparison group" do
    a, b = leaf("192.0.2.1"), leaf("192.0.2.2", acl: nil)
    a["snapshot"]["dimensions"]["configuration"]["status"] = "partial"
    result = audit(a, b)
    expect(result[:findings]).to include(include(code: "fabric_evidence_incomplete"))
    expect(result[:device_items].values.flatten.flat_map { |item| item[:commands] }).to be_empty
  end
end
