# frozen_string_literal: true

require_relative "spec_helper"
require "vxlan/observation"
require "vxlan/config"
require "vxlan/prefix_list_references"

RSpec.describe Vxlan::PrefixListReferences do
  it "connects a prefix list to every VRF exporting through its route map" do
    configuration = Vxlan::Config.new.parse(<<~CONFIG, complete: true).records.first
      hostname LEAF-01
      ip prefix-list GLOBAL seq 10 permit 192.0.2.0/24
      route-map EXPORT_GLOBAL permit 10
        match ip address prefix-list GLOBAL
      vrf context BLUE
        address-family ipv4 unicast
          export vrf default 100000 map EXPORT_GLOBAL allow-vpn
      vrf context GREEN
        address-family ipv4 unicast
          export vrf default map EXPORT_GLOBAL
    CONFIG

    references = described_class.new(configuration).call

    expect(references.fetch("GLOBAL")).to eq([
      { type: "route_map", name: "EXPORT_GLOBAL", sequence: 10, action: "permit", bindings: [
        { protocol: "vrf", vrf: "BLUE", address_family: "ipv4 unicast", usage: "export", target_vrf: "default" },
        { protocol: "vrf", vrf: "GREEN", address_family: "ipv4 unicast", usage: "export", target_vrf: "default" }
      ] }
    ])
  end
  it "retains network and inherited neighbor consumers with explicit direction overrides" do
    parsed = Vxlan::Config.new.parse(<<~CONFIG, complete: true)
      hostname LEAF-01
      ip prefix-list SOURCES seq 10 permit 192.0.2.0/24
      route-map INBOUND permit 10
        match ip route-source prefix-list SOURCES
      route-map OVERRIDE permit 10
        match ip next-hop prefix-list SOURCES
      router bgp 65000
        template peer EDGES
          address-family ipv4 unicast
            route-map INBOUND in
            route-map INBOUND out
        neighbor 192.0.2.1
          inherit peer EDGES
          address-family ipv4 unicast
            route-map OVERRIDE in
        address-family ipv4 unicast
          network 192.0.2.0/24 route-map INBOUND
    CONFIG
    expect(parsed).to be_complete
    callers = described_class.new(parsed.records.first).call.fetch("SOURCES")
    inbound = callers.find { |caller| caller[:name] == "INBOUND" }
    overridden = callers.find { |caller| caller[:name] == "OVERRIDE" }

    expect(inbound[:bindings]).to contain_exactly(
      { protocol: "bgp", process: "65000", vrf: "default", address_family: "ipv4 unicast", usage: "network", prefix: "192.0.2.0/24" },
      { protocol: "bgp", process: "65000", vrf: "default", address_family: "ipv4 unicast", usage: "neighbor_route_map", peer: "192.0.2.1", direction: "out" })
    expect(overridden[:bindings]).to eq([
      { protocol: "bgp", process: "65000", vrf: "default", address_family: "ipv4 unicast", usage: "neighbor_route_map", peer: "192.0.2.1", direction: "in" }
    ])
  end
end
