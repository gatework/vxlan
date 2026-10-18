# frozen_string_literal: true

require_relative "spec_helper"
require "vxlan/observation"
require "vxlan/configuration"

RSpec.describe Vxlan::Configuration do
  subject(:parser) { described_class.new }

  def parse(body, complete: true)
    parser.parse("hostname LEAF-01\n#{body}", complete: complete)
  end

  def fixture(name)
    File.read(File.expand_path("fixtures/netstack/#{name}.cfg", __dir__))
  end

  it "extracts the persisted topology from the NX-OS fixture" do
    observation = parser.parse(fixture("vxlan_topology"), complete: true)
    config = observation.records.fetch(0)

    expect(observation).to be_complete
    expect(config[:vpc_domain]).to include(id: 7, peer_gateway: true, peer_switch: true, layer3_peer_router: true)
    expect(config[:vpc_domain][:peer_keepalive]).to eq(source: "192.0.2.11", destination: "192.0.2.12", vrf: "management")
    expect(config[:interfaces]["Ethernet1/2"]).to include(vrf: "BLUE", ospf: "UNDERLAY area 0.0.0.1", addresses: [ "10.0.0.5/31" ])
    expect(config[:ospf]["UNDERLAY"][:vrfs]["BLUE"][:router_id]).to eq("192.0.2.111")
    expect(config[:nve][:members][10120]).to eq(associate_vrf: false, multicast_group: "239.1.1.20", suppress_arp: false)
    expect(config[:vrfs]["production"][:route_targets]).to eq([ { direction: "both", target: "auto", evpn: true, address_family: "ipv4 unicast" } ])
    expect(config[:segments]).to eq([ { vlan_id: 110, vni: 10110, vrf: "production", prefix: "10.110.0.0/24",
      gateway: "10.110.0.1", anycast: true, acl_bindings: {} } ])
    expect(config[:bgp][:templates]["SPINES"]).to include(remote_as: "65000", update_source: "Loopback0", bfd: true)
    expect(config[:bgp][:neighbors]["192.0.2.0/24"]).to include(inherit_peer: "SPINES", bfd: false)
    expect(config[:bgp][:vrfs]["BLUE"][:neighbors]["192.0.2.1"][:address_families]["l2vpn evpn"][:route_reflector_client]).to be(false)
  end

  it "retains separate prefix lists, route-map entries, and routing callers" do
    observation = parser.parse(fixture("vxlan_policies"), complete: true)
    config = observation.records.fetch(0)

    expect(observation).to be_complete
    expect(config[:features]).to eq([ "bgp", "nv overlay", "ospf" ])
    expect(config[:prefix_lists].keys).to contain_exactly("SHARED", "STAGED", "UNUSED")
    expect(config[:prefix_lists]["SHARED"]).to contain_exactly(
      { sequence: 20, action: "deny", prefix: "0.0.0.0/0", ge: nil, le: 32 },
      { sequence: 5, action: "permit", prefix: "10.10.0.0/16", ge: 24, le: 28 }
    )
    expect(config[:route_maps]["EXPORT"].map { |entry| entry[:sequence] }).to eq([ 10, 20 ])
    expect(config[:bgp][:address_families]["l2vpn evpn"][:retain_route_target]).to eq("route-map RETAIN")
    expect(config[:bgp][:vrfs]["BLUE"][:address_families]["ipv4 unicast"][:redistribute]).to eq([
      { protocol: "ospf", process: "UNDERLAY", route_map: "EXPORT" }
    ])
  end

  it "requires transport completeness even when the visible configuration is valid" do
    observation = parse("feature bgp\n", complete: false)

    expect(observation.status).to eq(:partial)
    expect(observation.issues).to include(code: :output_incomplete)
    expect(observation.records.first[:features]).to eq([ "bgp" ])
  end

  it "rejects malformed anycast gateway MACs without losing independent facts" do
    [ "garbage", "0200.0000.000", "0200.0000.000g", "0200-0000.0001", "02:00:00:00:00:01:02" ].each do |mac|
      observation = parse("fabric forwarding anycast-gateway-mac #{mac}\ninterface Ethernet1/1\n  mtu 1500\n")

      expect(observation.status).to eq(:partial), mac
      expect(observation.issues).to include(code: :invalid_configuration_value, line: 2)
      expect(observation.records.first).not_to have_key(:anycast_mac)
      expect(observation.records.first.dig(:interfaces, "Ethernet1/1", :mtu)).to eq(1500)
    end
  end

  it "preserves the public representation of valid anycast gateway MACs" do
    %w[0200.ABCD.0001 02:00:ab:cd:00:01 0200-abcd-0001 0200abcd0001].each do |mac|
      observation = parse("fabric forwarding anycast-gateway-mac #{mac}\n")

      expect(observation).to be_complete
      expect(observation.records.first[:anycast_mac]).to eq(mac)
    end
  end

  it "does not certify malformed static route next hops as complete facts" do
    %w[garbage 999.0.2.1 2001:db8::1 192.0.2.1/24].each do |hop|
      observation = parse("ip route 10.1.0.0/16 #{hop}\n")
      expect(observation.status).to eq(:partial)
      expect(observation.records.first[:static_routes]).to be_empty
    end
  end

  it "rejects malformed optional IPv4 next hops after an output interface" do
    [ "Ethernet1/2 999.0.2.1", "ethernet 1/2 2001:db8::1", "Vlan100 192.0.2.1/24", "port-channel 10 garbage" ].each do |hop|
      observation = parse("ip route 10.1.0.0/16 #{hop}\ninterface Ethernet1/1\n  mtu 1500\n")

      expect(observation.status).to eq(:partial), hop
      expect(observation.issues).to include(code: :invalid_configuration_value, line: 2)
      expect(observation.records.first[:static_routes]).to be_empty
      expect(observation.records.first.dig(:interfaces, "Ethernet1/1", :mtu)).to eq(1500)
    end
  end

  it "preserves interface route options with and without an optional next-hop address" do
    [
      [ "Ethernet1/2 name UPLINK tag 42 200", "Ethernet1/2", "name UPLINK tag 42 200" ],
      [ "ethernet 1/2 192.0.2.1 name UPLINK", "ethernet", "1/2 192.0.2.1 name UPLINK" ],
      [ "Vlan100 200", "Vlan100", "200" ],
      [ "port-channel 10 track 12", "port-channel", "10 track 12" ],
      [ "Ethernet1/2 vrf BLUE", "Ethernet1/2", "vrf BLUE" ]
    ].each do |hop, next_hop, options|
      observation = parse("ip route 10.1.0.0/16 #{hop}\n")

      expect(observation).to be_complete, hop
      expect(observation.records.first[:static_routes]).to eq([
        { prefix: "10.1.0.0/16", next_hop: next_hop, options: options }
      ])
    end
  end

  it "preserves documented interface and IPv4 static next hops" do
    [ "192.0.2.1", "ethernet 1/2 192.0.2.1", "Ethernet1/2", "port-channel 10", "Vlan100", "null 0" ].each do |hop|
      observation = parse("ip route 10.1.0.0/16 #{hop}\n")
      expect(observation).to be_complete
      expect(observation.records.first[:static_routes].first[:next_hop]).to eq(hop.split.first)
    end
  end

  [ :before, :after ].each do |position|
    it "accepts the NX-OS VLAN summary #{position} the individual VLAN definitions" do
      definition = "vlan 110\n  name BLUE\n  vn-segment 10110\nvlan 120\n  name STORAGE\n"
      summary = "vlan 1,110,120-121\n"
      observation = parse(position == :before ? summary + definition : definition + summary)

      expect(observation).to be_complete
      expect(observation.records.first[:vlan_vnis]).to eq(110 => 10110, 120 => nil)
    end
  end

  it "accepts vPC fast convergence without losing persisted domain settings" do
    observation = parse("vpc domain 10\n  peer-gateway\n  fast-convergence\n")

    expect(observation).to be_complete
    expect(observation.records.first[:vpc_domain]).to include(id: 10, peer_gateway: true)
  end

  it "retains VRF route exports and their route-map references" do
    observation = parse(<<~CONFIG)
      vrf context BLUE
        address-family ipv4 unicast
          route-target both auto evpn
          export vrf default 100000 map EXPORT_GLOBAL allow-vpn
        address-family ipv6 unicast
          export vrf default map EXPORT_V6
    CONFIG

    expect(observation).to be_complete
    expect(observation.records.first[:vrfs]["BLUE"][:exports]).to eq([
      { vrf: "default", prefix_limit: 100000, route_map: "EXPORT_GLOBAL", allow_vpn: true, address_family: "ipv4 unicast" },
      { vrf: "default", prefix_limit: nil, route_map: "EXPORT_V6", allow_vpn: false, address_family: "ipv6 unicast" }
    ])
  end

  it "requires a hostname before absence can replace existing inventory" do
    observation = parser.parse("feature bgp\n", complete: true)

    expect(observation).not_to be_complete
    expect(observation.issues).to include(code: :hostname_missing)
  end

  it "ignores unrelated credentials without retaining them in records or diagnostics" do
    observation = parse("username operator password 5 PRIVATE_VALUE role network-admin\nsnmp-server community PRIVATE_VALUE group network-operator\n")

    expect(observation).to be_complete
    expect(observation.to_h.to_s).not_to include("PRIVATE_VALUE", "username", "community")
  end

  it "reports unsupported modeled syntax without retaining its content" do
    observation = parse("router bgp 65000\n  password PRIVATE_VALUE\n")

    expect(observation).not_to be_complete
    expect(observation.issues).to include(code: :unsupported_configuration, line: 3)
    expect(observation.to_h.to_s).not_to include("PRIVATE_VALUE", "password")
  end

  it "does not infer absent EVPN neighbors from a missing peer template" do
    observation = parse("router bgp 65000\n  neighbor 192.0.2.1\n    inherit peer MISSING\n")

    expect(observation).not_to be_complete
    expect(observation.issues).to include(code: :missing_peer_template)
  end

  it "keeps unsupported template chains partial" do
    observation = parse("router bgp 65000\n  template peer SPINE\n    inherit peer BASE\n  template peer BASE\n    address-family l2vpn evpn\n")

    expect(observation).not_to be_complete
    expect(observation.issues).to include(code: :unsupported_peer_inheritance)
  end

  [
    "interface Ethernet1/1\n  ip address dhcp\n",
    "interface Ethernet1/1\n  no ip access-group OLD in\n",
    "interface nve1\n  unknown-vxlan-option\n",
    "vpc domain 10\n  fast-convergence unknown\n",
    "vrf context BLUE\n  address-family ipv4 unicast\n    export vrf default 1000 map EXPORT unknown\n",
    "router ospf UNDERLAY\n  unrecognized-routing-option\n",
    "unknown-context\n  interface Vlan110\n    ip address 10.0.0.1/24\n",
    "% Invalid command at '^' marker.\n",
    "--More--\n"
  ].each do |body|
    it "keeps #{body.lines.first.strip.inspect} partial when relevant data is unsupported" do
      expect(parse(body)).not_to be_complete
    end
  end

  [
    "vlan 1-4294967295\n",
    "vlan 1-2-3\n",
    "vlan 1,\n",
    "vlan 110\n  vn-segment 16777216\n",
    "vlan 110\n  vn-segment 10110\n  vn-segment 20110\n",
    "interface Vlan110\n  ip address 10.0.0.1/33\n",
    "interface Ethernet1/1\n  channel-group 99999\n",
    "interface nve1\n  member vni 100\n    mcast-group 192.0.2.1\n",
    "vpc domain 0\n",
    "vpc domain 10\n  peer-keepalive source invalid destination 192.0.2.1\n",
    "vpc domain 10\n  virtual peer-link source 192.0.2.1 source 192.0.2.2\n",
    "router bgp 4294967296\n",
    "router bgp 65000\n  neighbor 192.0.2.1\n    remote-as invalid\n",
    "ip prefix-list BROKEN seq 5 permit 192.0.2.0/24 ge 20\n",
    "ip prefix-list BROKEN seq 5 permit 192.0.2.0/24 ge 28 le 26\n",
    "ip prefix-list BROKEN seq 0 permit 192.0.2.0/24\n",
    "route-map BROKEN permit 0\n",
    "vrf context BLUE\n  address-family ipv4 unicast\n    export vrf default 0 map EXPORT\n",
    "vrf context BLUE\n  address-family ipv4 unicast\n    export vrf default 2147483648 map EXPORT\n"
  ].each do |body|
    it "rejects invalid values in #{body.lines.first.strip.inspect}" do
      observation = parse(body)

      expect(observation).not_to be_complete
      expect(observation.issues).to include(include(code: :invalid_configuration_value))
    end
  end

  it "drops ambiguous duplicate interface identities instead of selecting a segment" do
    observation = parse(<<~CONFIG)
      vlan 110
        vn-segment 10110
      interface Vlan110
        vrf member BLUE
        ip address 10.0.0.1/24
      interface Vlan110
        vrf member GREEN
        ip address 10.0.1.1/24
      interface Vlan110
        vrf member RED
        ip address 10.0.2.1/24
    CONFIG

    expect(observation).not_to be_complete
    expect(observation.records.first[:interfaces]).not_to have_key("Vlan110")
    expect(observation.records.first[:segments]).to be_empty
  end

  it "marks duplicate prefix sequences partial" do
    observation = parse("ip prefix-list LIST seq 5 permit 192.0.2.0/24\nip prefix-list LIST seq 5 deny 198.51.100.0/24\n")

    expect(observation).not_to be_complete
  end

  it "does not let a VLAN summary hide conflicting VNI mappings" do
    observation = parse(<<~CONFIG)
      vlan 110
        vn-segment 10110
      vlan 1,110
      vlan 110
        vn-segment 20110
    CONFIG

    expect(observation).not_to be_complete
    expect(observation.issues).to include(include(code: :duplicate_identity))
    expect(observation.records.first[:vlan_vnis]).not_to have_key(110)
  end

  [
    "interface Vlan110\n  ip address invalid\n",
    "vlan 110\n  vn-segment invalid\n"
  ].each do |duplicate|
    it "does not select a segment when a repeated identity contains invalid configuration" do
      observation = parse(<<~CONFIG + duplicate)
        vlan 110
          vn-segment 10110
        interface Vlan110
          vrf member BLUE
          ip address 10.0.0.1/24
      CONFIG

      expect(observation).not_to be_complete
      expect(observation.records.first[:segments]).to be_empty
    end
  end

  it "does not select one address from an SVI with multiple addresses" do
    observation = parse(<<~CONFIG)
      vlan 110
        vn-segment 10110
      interface Vlan110
        vrf member BLUE
        ip address 10.0.0.1/24
        ip address 10.0.1.1/24 secondary
    CONFIG

    expect(observation).not_to be_complete
    expect(observation.records.first[:segments]).to be_empty
    expect(observation.issues).to include(code: :unsupported_svi, interface: "Vlan110")
  end

  it "normalizes CRLF when computing the configuration digest" do
    text = "hostname LEAF-01\nfeature bgp\n"

    expect(parser.parse(text, complete: true).records.first[:config_digest]).to eq(
      parser.parse(text.gsub("\n", "\r\n"), complete: true).records.first[:config_digest]
    )
  end

  it "resolves forward template and VLAN references after all configuration blocks have been parsed" do
    observation = parse(<<~CONFIG)
      interface Vlan110
        vrf member BLUE
        ip address 10.110.0.1/24
      router bgp 65000
        neighbor 192.0.2.1
          inherit peer SPINES
        template peer SPINES
          remote-as 65000
      vlan 110
        vn-segment 10110
      feature ospf
      feature bgp
      feature ospf
    CONFIG

    expect(observation).to be_complete
    config = observation.records.fetch(0)
    expect(config[:features]).to eq(%w[bgp ospf])
    expect(config[:segments]).to eq([ { vlan_id: 110, vni: 10110, vrf: "BLUE", prefix: "10.110.0.0/24",
      gateway: "10.110.0.1", anycast: false, acl_bindings: {} } ])
  end

  it "rejects non-boolean completeness instead of treating truthy input as authoritative" do
    expect { parse("", complete: "true") }.to raise_error(ArgumentError, "Completeness must be boolean")
  end
end
