# frozen_string_literal: true

require_relative "../spec_helper"
require "vxlan/cisco_nxos/parsers/show_running_config"
require "vxlan/prefix_list_references"

RSpec.describe Vxlan::CiscoNxos::Parsers::ShowRunningConfig do
  subject(:parser) { described_class.new }

  def parse(body, complete: true)
    parser.parse("hostname LEAF\n#{body}", complete: complete)
  end

  it "normalizes real inline and nested multicast NVE declarations to the same fact" do
    inline = parse("interface nve1\n  member vni 10097 mcast-group 230.1.1.1\n")
    nested = parse("interface nve1\n  member vni 10097\n    mcast-group 230.1.1.1\n")

    expect(inline).to be_complete
    expect(nested).to be_complete
    expect(inline.records.first[:nve]).to eq(nested.records.first[:nve])
    expect(inline.records.first.dig(:nve, :members, 10097)).to include(multicast_group: "230.1.1.1")
  end

  [ "member vni 10097 mcast-group 192.0.2.1", "member vni 10097 mcast-group 230.1.1.1\n    mcast-group 230.1.1.2",
    "member vni 10097 mcast-group 230.1.1.1\n    ingress-replication protocol bgp" ].each do |member|
    it "rejects invalid or conflicting multicast member #{member.lines.first}" do
      expect(parse("interface nve1\n  #{member}\n")).not_to be_complete
    end
  end

  it "excludes conflicting member identities rather than selecting a replication mode" do
    result = parse("interface nve1\n  member vni 10097 mcast-group 230.1.1.1\n  member vni 10097\n    ingress-replication protocol bgp\n")

    expect(result).not_to be_complete
    expect(result.records.first[:nve][:members]).to be_empty
  end

  it "models global breakout and disabled features without inventing an interface" do
    result = parse("interface breakout module 1 port 53 map 10g-4x\nno feature signature-verification\nfeature bgp\n")
    config = result.records.first

    expect(result).to be_complete
    expect(config[:interfaces]).to be_empty
    expect(config[:breakouts]["1/53"]).to eq(module_id: 1, port: 53, map: "10g-4x")
    expect(config[:disabled_features]).to eq([ "signature-verification" ])
    expect(config[:features]).to eq([ "bgp" ])
  end

  it "keeps contradictory feature enablement partial" do
    result = parse("feature bgp\nno feature bgp\n")

    expect(result).not_to be_complete
    expect(result.issues).to include(code: :conflicting_feature_state)
  end

  it "isolates banner bodies that look like configuration and resumes after their delimiter" do
    result = parse(<<~CONFIG)
      banner motd ^C
      feature IMAGINARY
      interface Ethernet1/99
        ip address 192.0.2.1/24
        ip router ospf FAKE area 0
      ^C
      feature bgp
      interface Ethernet1/1
        no shutdown
    CONFIG

    expect(result).to be_complete
    expect(result.records.first[:features]).to eq([ "bgp" ])
    expect(result.records.first[:interfaces].keys).to eq([ "Ethernet1/1" ])
    expect(result.to_h.inspect).not_to include("IMAGINARY", "FAKE")
  end

  it "accepts inline banners without consuming subsequent configuration" do
    result = parse("banner motd #PRIVATE_VALUE#\nfeature bgp\n")

    expect(result).to be_complete
    expect(result.records.first[:features]).to eq([ "bgp" ])
    expect(result.to_h.inspect).not_to include("PRIVATE_VALUE")
  end

  it "retains an explicit incomplete banner diagnostic" do
    result = parse("banner motd #\nfeature IMAGINARY\n")

    expect(result).not_to be_complete
    expect(result.issues).to include(code: :incomplete_banner)
    expect(result.records.first[:features]).to be_empty
  end

  it "retains neighbor policy, next-hop behavior, descriptions and EVPN switches in their original family" do
    result = parse(<<~CONFIG)
      router bgp 65000
        vrf BLUE
          neighbor 192.0.2.1
            description EDGE
            address-family ipv4 unicast
              route-map IMPORT in
              next-hop-self all
              send-community both
          address-family ipv4 unicast
            advertise l2vpn evpn
            advertise-pip
    CONFIG
    scope = result.records.first.dig(:bgp, :vrfs, "BLUE")
    family = scope.dig(:neighbors, "192.0.2.1", :address_families, "ipv4 unicast")

    expect(result).to be_complete
    expect(scope[:neighbors]["192.0.2.1"][:description]).to eq("EDGE")
    expect(family).to include(route_maps: { in: "IMPORT" }, next_hop_self: true, next_hop_self_all: true,
      standard_community: true, extended_community: true)
    expect(scope[:address_families]["ipv4 unicast"]).to include(advertise_l2vpn_evpn: true, advertise_pip: true)
    expect(scope[:neighbors]["192.0.2.1"][:route_maps]).to be_nil
  end

  it "retains explicit disabled publication and community switches" do
    result = parse("router bgp 65000\n  address-family l2vpn evpn\n    no send-community both\n    no advertise-pip\n    no next-hop-self\n")

    expect(result).to be_complete
    expect(result.records.first.dig(:bgp, :address_families, "l2vpn evpn")).to include(
      standard_community: false, extended_community: false, advertise_pip: false, next_hop_self: false, next_hop_self_all: false)
  end

  it "does not swallow modeled commands nested below an ignored routing leaf" do
    result = parse("router bgp 65000\n  log-neighbor-changes\n    neighbor 192.0.2.1\n      remote-as 65000\n")

    expect(result).not_to be_complete
    expect(parser.cursor.state(3)).to eq(:unsupported)
    expect(result.records.first[:bgp][:neighbors]).to be_empty
  end

  it "retains VXLAN-relevant interface behavior as parsed facts and captures" do
    result = parse(<<~CONFIG)
      interface Ethernet1/1
        mtu 9216
        no switchport
        ip ospf network point-to-point
      interface Ethernet1/2
        switchport mode access
        switchport access vlan 110
      interface Vlan110
        ip forward
      interface nve1
        description UPLINK
        advertise virtual-rmac
    CONFIG
    config = result.records.first

    expect(result).to be_complete
    expect(config[:interfaces]["Ethernet1/1"]).to include(mtu: 9216, switchport: false, ospf_network_type: "point-to-point")
    expect(config[:interfaces]["Ethernet1/2"]).to include(access_vlan: 110, switchport_mode: "access")
    expect(config[:interfaces]["Vlan110"][:ip_forward]).to be(true)
    expect(config[:nve]).to include(description: "UPLINK", advertise_virtual_rmac: true)
    expect(parser.cursor.captures_for([ :interfaces, "Ethernet1/1" ]).first.data).to eq(config[:interfaces]["Ethernet1/1"])
  end

  it "resolves a case-insensitive unnumbered loopback reference without altering the explicit source facts" do
    result = parse("interface Ethernet1/1\n  ip unnumbered loopback0\n  ip router ospf UNDERLAY area 0\ninterface Loopback0\n  ip address 192.0.2.1/32\n")
    config = result.records.first

    expect(result).to be_complete
    expect(config[:unnumbered_addresses]).to eq("Ethernet1/1" => [ "192.0.2.1/32" ])
    expect(config[:interfaces]["Ethernet1/1"][:addresses]).to eq([])
    expect(parser.cursor.captures_for([ :interfaces, "Ethernet1/1" ]).first.data).to eq(config[:interfaces]["Ethernet1/1"])
  end

  [ "", "interface loopback0\n  ip address 192.0.2.1/32\n  vrf member BLUE\n",
    "interface loopback0\n  ip unnumbered loopback0\n" ].each do |source|
    it "does not claim complete underlay coverage for an unresolved or inconsistent borrowed address" do
      result = parse("interface Ethernet1/1\n  ip unnumbered loopback0\n#{source}")

      expect(result).not_to be_complete
      expect(result.issues).to include(include(code: :unresolved_unnumbered_interface))
      expect(result.records.first[:unnumbered_addresses]).to be_empty
    end
  end

  it "separates same-named IPv4 and IPv6 lists and captures all prefix selectors" do
    result = parse(<<~CONFIG)
      ip prefix-list SHARED seq 10 permit 192.0.2.0/24 ge 25 le 32
      ipv6 prefix-list SHARED seq 10 permit 2001:db8::/32 ge 48 le 128
      route-map FILTER permit 10
        match ip next-hop prefix-list SHARED
        match ip route-source prefix-list SHARED
        match ipv6 address prefix-list SHARED
    CONFIG
    config = result.records.first
    ipv4 = Vxlan::PrefixListReferences.new(config).call
    ipv6 = Vxlan::PrefixListReferences.new(config).call(address_family: "ipv6")

    expect(result).to be_complete
    expect(config[:prefix_lists]["SHARED"].first[:prefix]).to eq("192.0.2.0/24")
    expect(config[:ipv6_prefix_lists]["SHARED"].first[:prefix]).to eq("2001:db8::/32")
    expect(ipv4["SHARED"].map { |caller| caller[:selector] }).to contain_exactly("next-hop", "route-source")
    expect(ipv6["SHARED"].size).to eq(1)
    expect(parser.cursor.captures_for([ :ipv6_prefix_lists, "SHARED", 0 ]).first.data).to eq(config[:ipv6_prefix_lists]["SHARED"].first)
  end

  [ "ipv6 prefix-list BAD seq 10 permit 192.0.2.0/24", "ipv6 prefix-list BAD seq 10 permit 2001:db8::/32 le 129",
    "ipv6 prefix-list BAD seq 10 permit 2001:db8::/64 ge 32", "mtu invalid" ].each do |line|
    it "rejects invalid modeled syntax #{line}" do
      body = line.start_with?("mtu") ? "interface Ethernet1/1\n  #{line}\n" : "#{line}\n"
      expect(parse(body)).not_to be_complete
    end
  end

  it "does not report absent associations from incomplete evidence" do
    result = parse("vlan 110\n  vn-segment 10110\n", complete: false)

    expect(result.status).to eq(:partial)
    expect(result.records.first[:review_status]).to eq(:partial)
    expect(result.records.first[:review_findings]).to be_empty
  end

  it "reports association findings independently from syntactic completeness" do
    result = parse("vlan 110\n  vn-segment 10110\ninterface nve1\n  member vni 10120\n    ingress-replication protocol bgp\nnv overlay evpn\n")

    expect(result).to be_complete
    expect(result.records.first[:review_findings]).to include(
      { code: :vlan_vni_without_nve, vni: 10110, vlan_ids: [ 110 ] },
      { code: :nve_l2_without_vlan, vni: 10120 }, { code: :nve_l2_without_evpn, vni: 10120 })
  end
end
