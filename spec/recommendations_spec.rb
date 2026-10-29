# frozen_string_literal: true

require_relative "spec_helper"
require "json"

RSpec.describe "VXLAN remediation recommendations" do
  let(:config) do
    <<~CONFIG
      hostname LEAF
      feature nv overlay
      feature vn-segment-vlan-based
      nv overlay evpn
      vlan 95
        vn-segment 10095
      vlan 96
        vn-segment 10096
      interface nve1
        no shutdown
        host-reachability protocol bgp
        source-interface loopback0
        member vni 10095
          ingress-replication protocol bgp
        member vni 10096
          ingress-replication protocol bgp
      evpn
        vni 10096 l2
          rd auto
          route-target import auto
          route-target export auto
    CONFIG
  end

  def review(body, complete: true)
    observation = Vxlan::Config.new.parse(body, complete: complete)
    document = JSON.parse(JSON.generate(device: { host: "192.0.2.1", name: "LEAF" }, snapshot: { observations: { configuration: observation.to_h } }))
    Vxlan::Recommendations.new(document).call
  end

  it "generates a conditional EVPN addition with verification and a narrowly scoped rollback" do
    item = review(config).fetch(:items).find { |r| r[:code] == "nve_l2_without_evpn" }
    expect(item).to include(status: "candidate", scope: "VNI 10095")
    expect(item[:commands]).to include("  vni 10095 l2", "    rd auto")
    expect(item[:rollback]).to include("  no vni 10095 l2")
    expect(item[:verify]).to include("show nve vni")
    expect(item[:prerequisites]).not_to be_empty
  end

  it "reports undefined ACL references even on an SVI without a VNI or gateway" do
    result = review("hostname LEAF\ninterface Vlan1100\n  ip access-group absent out\n")
    expect(result[:items]).to include(include(code: "acl_reference_undefined", scope: "Vlan1100 / out", status: "blocked", commands: []))
  end

  it "replaces a local unresolved finding only with a proven cross-device candidate for that VNI" do
    local = { items: [ { code: "nve_l2_without_vlan", vni: 10008, status: "blocked" }, { code: "nve_l2_without_vlan", vni: 10009, status: "blocked" } ] }
    addition = { code: "fabric_vlan_mapping_missing", status: "candidate", resolves: [ { code: "nve_l2_without_vlan", vni: 10008 } ] }
    combined = Vxlan::Recommendations.combine(local, [ addition ])
    expect(combined[:items]).to eq([ local[:items].last, addition ])
    expect(combined[:counts]).to eq("blocked" => 1, "candidate" => 1)
    expect(Vxlan::Recommendations.combine(local, [ addition.merge(status: "blocked") ])[:items].size).to eq(3)
  end

  it "withdraws local script drafts when explicit Fabric evidence identifies a role conflict" do
    local = { items: [ { code: "nve_l2_without_evpn", status: "candidate", commands: [ "command" ], rollback: [ "undo" ], blockers: [] } ] }
    conflict = { code: "fabric_role_conflict", status: "blocked", blockers: [ "role requires review" ] }
    advice = Vxlan::Recommendations.combine(local, [ conflict ])
    expect(advice[:items].first).to include(status: "blocked", commands: [], rollback: [], blockers: include("role requires review"))
    expect(local[:items].first[:status]).to eq("candidate")
  end

  it "does not infer auto route targets when the existing policy is mixed" do
    result = review(config.sub("route-target import auto", "route-target import 65001:10096"))
    expect(result[:items].find { |r| r[:code] == "nve_l2_without_evpn" }).to include(status: "blocked", commands: [])
  end

  it "does not fabricate a VLAN from the VNI suffix or activate a VNI lacking VLAN evidence" do
    item = review(config.sub("  vn-segment 10095\n", "")).fetch(:items).find { |r| r[:code] == "nve_l2_without_evpn" }
    expect(item).to include(status: "blocked", commands: [])
  end

  it "keeps incomplete configuration as an evidence task with no configuration script" do
    result = review(config, complete: false)
    expect(result[:items]).to include(include(code: "evidence_incomplete"))
    expect(result[:items].flat_map { |r| r[:commands] }).to be_empty
  end

  it "requests evidence instead of silently accepting an incomplete configuration record" do
    observation = Vxlan::Config.new.parse(config, complete: true)
    document = JSON.parse(JSON.generate(device: { host: "192.0.2.1", name: "LEAF" }, snapshot: { observations: { configuration: observation.to_h } }))
    [ "partial", nil ].each do |status|
      document["snapshot"]["observations"]["configuration"]["records"][0]["review_status"] = status
      result = Vxlan::Recommendations.new(document).call
      expect(result[:items]).to include(include(code: "evidence_incomplete", scope: "configuration", status: "investigate"))
      expect(result[:items].flat_map { |item| item[:commands] }).to be_empty
    end
  end

  it "requests evidence when a complete observation contains multiple configuration records" do
    observation = Vxlan::Config.new.parse(config, complete: true)
    document = JSON.parse(JSON.generate(device: { host: "192.0.2.1", name: "LEAF" }, snapshot: { observations: { configuration: observation.to_h } }))
    records = document["snapshot"]["observations"]["configuration"]["records"]
    records << records.first.dup
    result = Vxlan::Recommendations.new(document).call
    expect(result[:items]).to include(include(code: "evidence_incomplete", scope: "configuration", status: "investigate"))
    expect(result[:items].flat_map { |item| item[:commands] }).to be_empty
  end

  it "builds NVE and EVPN together when the VLAN is mapped but both bindings are missing" do
    body = config.sub("  member vni 10095\n    ingress-replication protocol bgp\n", "")
    item = review(body).fetch(:items).find { |r| r[:code] == "vlan_vni_without_nve" }
    expect(item[:commands]).to include("  member vni 10095", "  vni 10095 l2")
    expect(item[:rollback]).to include("  no member vni 10095", "  no vni 10095 l2")
  end
end
