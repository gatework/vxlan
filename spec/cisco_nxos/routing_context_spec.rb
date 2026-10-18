# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe "NX-OS routing context" do
  def parse(body)
    Vxlan::Configuration.new.parse("hostname LEAF\n#{body}", complete: true)
  end

  it "rejects cross-family networks before projecting policy consumers" do
    [ [ "ipv4 unicast", "2001:db8::/32" ], [ "ipv6 unicast", "192.0.2.0/24" ] ].each do |family, prefix|
      result = parse("router bgp 65000\n  address-family #{family}\n    network #{prefix} route-map POLICY\n" \
        "route-map POLICY permit 10\n  match ip address prefix-list LIST\n")

      expect(result.status).to eq(:partial)
      expect(result.issues).to include(include(code: :invalid_configuration_value))
      expect(result.records.first.dig(:bgp, :address_families, family, :networks)).to be_nil
      references = Vxlan::PrefixListReferences.new(result.records.first).call
      expect(references.fetch("LIST").first[:bindings]).to be_empty
    end
  end

  it "keeps matching IPv4 and IPv6 network families and VRFs independent" do
    result = parse(<<~CONFIG)
      router bgp 65000
        address-family ipv4 unicast
          network 192.0.2.0/24
        vrf BLUE
          address-family ipv6 unicast
            network 2001:db8::/32
    CONFIG

    expect(result).to be_complete
    bgp = result.records.first[:bgp]
    expect(bgp.dig(:address_families, "ipv4 unicast", :networks)).to eq([ { prefix: "192.0.2.0/24" } ])
    expect(bgp.dig(:vrfs, "BLUE", :address_families, "ipv6 unicast", :networks)).to eq([ { prefix: "2001:db8::/32" } ])
  end

  it "does not accept BGP-only leaves as OSPF facts" do
    [ "remote-as 65100", "inherit peer BASE", "update-source Loopback0", "route-map POLICY in",
      "send-community both", "next-hop-self", "retain route-target all", "advertise l2vpn evpn" ].each do |setting|
      result = parse("router ospf UNDERLAY\n  #{setting}\ninterface Ethernet1/1\n  mtu 1500\n")

      expect(result.status).to eq(:partial), setting
      expect(result.issues).to include(include(code: :unsupported_configuration))
      expect(result.records.first[:ospf]["UNDERLAY"]).to eq(
        vrfs: {}, neighbors: {}, templates: {}, address_families: {}, redistribute: [])
      expect(result.records.first.dig(:interfaces, "Ethernet1/1", :mtu)).to eq(1500)
    end
  end

  it "does not project a neighbor network as a process network" do
    result = parse("router bgp 65000\n  neighbor 192.0.2.1\n    address-family ipv4 unicast\n      network 198.51.100.0/24\n")

    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :unsupported_configuration))
    neighbor = result.records.first.dig(:bgp, :neighbors, "192.0.2.1")
    expect(neighbor.dig(:address_families, "ipv4 unicast", :networks)).to be_nil
  end

  it "withholds misplaced BGP settings and invented address families" do
    [ "  route-map POLICY in\n",
      "  neighbor 192.0.2.1\n    redistribute direct route-map POLICY\n",
      "  address-family arbitrary garbage\n    redistribute direct route-map POLICY\n",
      "  address-family ipv4 unicast\n    retain route-target route-map POLICY\n",
      "  address-family l2vpn evpn\n    remote-as 65100\n",
      "  inherit peer MISSING\n", "  update-source Loopback0\n" ].each do |body|
      result = parse("router bgp 65000\n#{body}route-map POLICY permit 10\n  match ip address prefix-list LIST\n")

      expect(result.status).to eq(:partial), body
      expect(result.issues).to include(include(code: :unsupported_configuration))
      expect(Vxlan::PrefixListReferences.new(result.records.first).call.fetch("LIST").first[:bindings]).to be_empty
    end
  end

  it "requires IPv4 router identities in BGP and OSPF" do
    [ "bgp 65000", "ospf UNDERLAY" ].each do |process|
      result = parse("router #{process}\n  router-id 2001:db8::1\n")

      expect(result.status).to eq(:partial)
      expect(result.issues).to include(include(code: :invalid_configuration_value))
    end
  end
end
