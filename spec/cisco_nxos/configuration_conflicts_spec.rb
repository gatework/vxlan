# frozen_string_literal: true

require_relative "../spec_helper"
require "vxlan/cisco_nxos/parsers/show_running_config"

RSpec.describe Vxlan::CiscoNxos::Parsers::ShowRunningConfig do
  subject(:parser) { described_class.new }

  it "removes conflicting singleton facts in either order and does not restore them on a third declaration" do
    cases = [
      [ "interface Ethernet1/1", "mtu 1500", "mtu 9000", [ :interfaces, "Ethernet1/1", :mtu ] ],
      [ "interface Ethernet1/1", "ip access-group FIRST in", "ip access-group SECOND in", [ :interfaces, "Ethernet1/1", :acl_bindings, :in ] ],
      [ "interface Ethernet1/1", "shutdown", "no shutdown", [ :interfaces, "Ethernet1/1", :shutdown ] ],
      [ "interface nve1", "source-interface Loopback0", "source-interface Loopback1", [ :nve, :source_interface ] ],
      [ "interface nve1\n  member vni 10010", "suppress-arp", "no suppress-arp", [ :nve, :members, 10010, :suppress_arp ] ],
      [ "router bgp 65000\n  neighbor 192.0.2.1", "remote-as 65001", "remote-as 65002", [ :bgp, :neighbors, "192.0.2.1", :remote_as ] ],
      [ "router bgp 65000\n  neighbor 192.0.2.1\n    address-family l2vpn evpn", "route-map FIRST in", "route-map SECOND in", [ :bgp, :neighbors, "192.0.2.1", :address_families, "l2vpn evpn", :route_maps, :in ] ],
      [ "router bgp 65000\n  address-family l2vpn evpn", "send-community both", "no send-community extended", [ :bgp, :address_families, "l2vpn evpn", :extended_community ] ],
      [ "vrf context BLUE", "vni 10010", "vni 10020", [ :vrfs, "BLUE", :vni ] ],
      [ "vpc domain 1", "peer-keepalive destination 192.0.2.1", "peer-keepalive destination 192.0.2.2", [ :vpc_domain, :peer_keepalive ] ]
    ]
    cases.each do |parent, first, second, path|
      [ [ first, second, first ], [ second, first, second ] ].each do |commands|
        indent = parent.lines.last[/\A */] + "  "
        result = parser.parse("hostname LEAF\n#{parent}\n" + commands.map { |line| "#{indent}#{line}\n" }.join, complete: true)
        expect(result.status).to eq(:partial), path.inspect
        expect(result.records.first.dig(*path)).to be_nil, path.inspect
        expect(result.issues).to include(include(code: :conflicting_configuration_value))
        expect(result.records.first[:review_findings]).to be_empty
        expect(parser.cursor.state(parent.lines.size + 1)).to eq(:invalid)
      end
    end
  end

  it "accepts repeated equal singleton values and resets conflicts between invocations" do
    valid = "hostname LEAF\ninterface Ethernet1/1\n  mtu 1500\n  mtu 1500\n"
    expect(parser.parse(valid, complete: true)).to be_complete
    expect(parser.parse(valid + "  mtu 9000\n", complete: true).status).to eq(:partial)
    expect(parser.parse(valid, complete: true)).to be_complete
  end

  it "marks conflicting global switches partial without selecting the last value" do
    result = parser.parse("hostname LEAF\nnv overlay evpn\nno nv overlay evpn\nnv overlay evpn\n", complete: true)
    expect(result.status).to eq(:partial)
    expect(result.records.first).not_to have_key(:nv_overlay_evpn)
    expect(parser.cursor.state(1)).to eq(:invalid)
    expect(parser.cursor.state(2)).to eq(:invalid)
  end

  it "rejects structural routing scopes which cannot be represented by the public neighbor projection" do
    [ "router bgp 65000\n  neighbor 192.0.2.1\n    vrf BLUE\n      neighbor 192.0.2.2\n",
      "router bgp 65000\n  address-family l2vpn evpn\n    address-family l2vpn evpn\n",
      "router ospf UNDERLAY\n  neighbor 192.0.2.1\n    remote-as 65000\n" ].each do |body|
      result = parser.parse("hostname LEAF\n#{body}", complete: true)
      expect(result.status).to eq(:partial)
      expect(result.issues).to include(include(code: :unsupported_configuration))
    end
  end

  it "walks deeply nested unrelated configuration without consuming the Ruby call stack" do
    body = (0...4000).map { |depth| "#{' ' * depth}unrelated\n" }.join
    result = parser.parse("hostname LEAF\n#{body}#{' ' * 4000}mtu 9000\n", complete: true)
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(code: :unsupported_configuration, line: 4002)
    expect(parser.cursor.state(4001)).to eq(:unsupported)
  end

  it "stops unsupported recursive routing scopes while preserving subsequent sibling facts" do
    nested = (1..4000).map { |depth| "#{' ' * depth}vrf NESTED\n" }.join
    result = parser.parse("hostname LEAF\nrouter bgp 65000\n#{nested}interface Ethernet1/1\n  mtu 1500\n", complete: true)
    expect(result.status).to eq(:partial)
    expect(result.records.first.dig(:interfaces, "Ethernet1/1", :mtu)).to eq(1500)
    expect(result.records.first.dig(:bgp, :vrfs, "NESTED", :vrfs)).to be_empty
  end

  it "rejects terminal controls in ignored configuration as well as modeled facts" do
    [ "logging server 192.0.2.1\b", "interface Ethernet1/1\n  description hello\bworld" ].each do |body|
      result = parser.parse("hostname LEAF\n#{body}\n", complete: true)
      expect(result.status).to eq(:partial)
      expect(result.issues).to include(include(code: :incomplete_configuration))
    end
  end
  it "excludes conflicted BGP neighbors before template inheritance can restore their fields" do
    [ "    remote-as 65200\n    remote-as 65300\n    remote-as 65200\n",
      "    address-family ipv4 unicast\n      route-map FIRST in\n      route-map SECOND in\n      route-map FIRST in\n",
      "    address-family ipv4 unicast\n      route-map FIRST in\n    address-family ipv4 unicast\n      route-map SECOND in\n" ].each do |conflict|
      source = "hostname LEAF\nrouter bgp 65000\n" \
        "  template peer BASE\n    remote-as 65100\n    address-family ipv4 unicast\n      route-map BASE_MAP in\n" \
        "  neighbor 192.0.2.1\n    inherit peer BASE\n#{conflict}" \
        "  neighbor 192.0.2.2\n    remote-as 65400\n" \
        "route-map BASE_MAP permit 10\n  match ip address prefix-list LIST\n"
      result = parser.parse(source, complete: true)
      settings = result.records.first
      expect(result.status).to eq(:partial)
      expect(settings.dig(:bgp, :neighbors).keys).to eq([ "192.0.2.2" ])
      expect(Vxlan::BgpNeighbors.new(settings[:bgp]).map { |_vrf, peer, _values| peer }).to eq([ "192.0.2.2" ])
      expect(Vxlan::PrefixListReferences.new(settings).call.fetch("LIST").first[:bindings]).to be_empty
    end
  end

  it "excludes conflicted peer templates and never projects neighbors with unresolved inheritance" do
    [ "    remote-as 65100\n    remote-as 65200\n",
      "    address-family ipv4 unicast\n      route-map FIRST in\n      route-map SECOND in\n" ].each do |conflict|
      source = "hostname LEAF\nrouter bgp 65000\n  template peer BASE\n#{conflict}" \
        "  neighbor 192.0.2.1\n    inherit peer BASE\n    description Ambiguous\n" \
        "  neighbor 192.0.2.2\n    remote-as 65400\n"
      [ source, source + "  template peer BASE\n    remote-as 65100\n" ].each do |body|
        result = parser.parse(body, complete: true)
        expect(result.status).to eq(:partial)
        expect(result.records.first.dig(:bgp, :templates)).not_to have_key("BASE")
        expect(result.issues).to include(include(code: :missing_peer_template))
        expect(Vxlan::BgpNeighbors.new(result.records.first[:bgp]).map { |_vrf, peer, _values| peer }).to eq([ "192.0.2.2" ])
      end
    end
  end

  it "does not infer default-VRF unnumbered addresses from a conflicted source or borrower" do
    [ "loopback0", "Ethernet1/1" ].each do |conflicted|
      conflict = "  vrf member BLUE\n  vrf member RED\n  vrf member BLUE\n"
      source = "hostname LEAF\ninterface loopback0\n  ip address 192.0.2.1/32\n" \
        "#{conflicted == 'loopback0' ? conflict : ''}" \
        "interface Ethernet1/1\n  ip unnumbered loopback0\n" \
        "#{conflicted == 'Ethernet1/1' ? conflict : ''}" \
        "interface Ethernet1/2\n  mtu 1500\n"
      result = parser.parse(source, complete: true)
      expect(result.status).to eq(:partial)
      expect(result.records.first[:unnumbered_addresses]).to be_empty
      expect(result.records.first[:interfaces]).not_to have_key(conflicted)
      expect(result.records.first.dig(:interfaces, "Ethernet1/2", :mtu)).to eq(1500)
    end
  end

  it "excludes repeated global identities permanently and preserves independent scopes" do
    cases = [
      [ "hostname FIRST", "hostname SECOND", :hostname, nil, :duplicate_hostname ],
      [ "router bgp 65000\n  neighbor 192.0.2.1\n    remote-as 65100", "router bgp 65001\n  neighbor 192.0.2.2\n    remote-as 65200", :bgp, {}, :duplicate_bgp_process ],
      [ "interface nve1\n  source-interface loopback0\n  member vni 10010", "interface nve2\n  source-interface loopback1\n  member vni 10020", :nve, { members: {} }, :multiple_nve_interfaces ],
      [ "vpc domain 1\n  peer-switch", "vpc domain 2\n  peer-gateway", :vpc_domain, nil, :duplicate_vpc_domain ]
    ]
    cases.each do |first, second, key, empty_value, issue_code|
      [ [ first, second, first ], [ second, first, second ] ].each do |commands|
        prefix = key == :hostname ? "" : "hostname LEAF\n"
        source = prefix + commands.join("\n") + "\ninterface Ethernet1/1\n  mtu 1500\n"
        result = parser.parse(source, complete: true)
        configuration = result.records.first
        expect(result.status).to eq(:partial), key.inspect
        expect(configuration.fetch(key)).to eq(empty_value), key.inspect
        expect(result.issues).to include(include(code: issue_code))
        expect(parser.cursor.state(prefix.lines.size)).to eq(:invalid)
        expect(parser.cursor.captures_for([ key ])).not_to be_empty
        expect(parser.cursor.captures_for([ key ]).map(&:complete?)).to eq([ false ])
        expect(configuration.dig(:interfaces, "Ethernet1/1", :mtu)).to eq(1500)
        expect(Vxlan::BgpNeighbors.new(configuration.fetch(:bgp)).to_a).to be_empty
        expect(Vxlan::PrefixListReferences.new(configuration).call).to be_empty
        expect(Vxlan::Config::Review.new(configuration).call(complete: true)).to be_empty
      end
    end
  end

  it "does not project neighbors or policy bindings through unsupported template inheritance" do
    source = "hostname LEAF\nrouter bgp 65000\n" \
      "  template peer BASE\n    remote-as 65100\n" \
      "  template peer CHILD\n    inherit peer BASE\n    remote-as 65200\n" \
      "    address-family ipv4 unicast\n      route-map POLICY in\n" \
      "  neighbor 192.0.2.1\n    inherit peer CHILD\n" \
      "  neighbor 192.0.2.2\n    remote-as 65300\n" \
      "route-map POLICY permit 10\n  match ip address prefix-list LIST\n"
    result = parser.parse(source, complete: true)
    configuration = result.records.first
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :unsupported_peer_inheritance))
    expect(Vxlan::BgpNeighbors.new(configuration.fetch(:bgp)).map { |_vrf, peer, _values| peer }).to eq([ "192.0.2.2" ])
    expect(Vxlan::PrefixListReferences.new(configuration).call.fetch("LIST").first[:bindings]).to be_empty
  end

  it "keeps global identities excluded when either declaration has an invalid identifier", :aggregate_failures do
    [ [ "router bgp 65000", "router bgp 4294967296", :bgp, {} ],
      [ "vpc domain 1", "vpc domain 1001", :vpc_domain, nil ] ].each do |valid, invalid, key, empty_value|
      [ [ valid, invalid ], [ invalid, valid ], [ valid, invalid, valid ], [ invalid, valid, valid ] ].each do |commands|
        aggregate_failures([ key, commands.first ].inspect) do
          source = "hostname LEAF\n" + commands.join("\n") + "\ninterface Ethernet1/1\n  mtu 1500\n"
          result = parser.parse(source, complete: true)
          expect(result.status).to eq(:partial)
          expect(result.records.first.fetch(key)).to eq(empty_value)
          expect(result.records.first.dig(:interfaces, "Ethernet1/1", :mtu)).to eq(1500)
          expect(parser.cursor.state(1)).to eq(:invalid)
          expect(parser.cursor.captures_for([ key ]).all? { |capture| !capture.complete? }).to be(true)
        end
      end
    end
  end
end
