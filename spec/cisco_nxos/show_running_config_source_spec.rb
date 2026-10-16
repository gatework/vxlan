# frozen_string_literal: true

require_relative "../spec_helper"
require "vxlan/cisco_nxos/parsers/show_running_config"

RSpec.describe Vxlan::CiscoNxos::Parsers::ShowRunningConfig do
  subject(:parser) { described_class.new }

  it "associates an interface projection with its exact original configuration subtree" do
    source = "hostname LEAF\r\ninterface Vlan10\r\n  description Users\r\n  vrf member BLUE\r\n  ip address 10.0.10.1/24\r\n! retained comment\r\n\r\ninterface Ethernet1/1\r\n  no shutdown\r\nend\r\n"
    result = parser.parse(source, complete: true)
    capture = parser.cursor.captures_for([ :interfaces, "Vlan10" ]).fetch(0)

    expect(result).to be_complete
    expect(capture.data).to eq(result.records.first[:interfaces]["Vlan10"])
    expect(capture.content).to eq(source.split("interface Ethernet1/1").first.delete_prefix("hostname LEAF\r\n"))
    expect(capture.block.line_range).to eq(2..7)
    expect(capture.block.children.map(&:line)).to eq([ 3, 4, 5 ])
    expect(capture.block).to be_complete
    expect(parser.cursor.position).to eq(parser.cursor.size)
    expect(result.to_h.keys).to contain_exactly(:status, :records, :issues)
  end

  it "captures nested NVE and BGP contexts at their projected data paths" do
    result = parser.parse(<<~CONFIG, complete: true)
      hostname LEAF
      interface nve1
        source-interface Loopback0
        member vni 10110
          ingress-replication protocol bgp
          suppress-arp
      router bgp 65000
        template peer SPINES
          remote-as 65000
        neighbor 192.0.2.1
          inherit peer SPINES
          address-family l2vpn evpn
            send-community extended
    CONFIG
    paths = [ [ :nve, :members, 10110 ], [ :bgp, :templates, "SPINES" ],
      [ :bgp, :neighbors, "192.0.2.1" ], [ :bgp, :neighbors, "192.0.2.1", :address_families, "l2vpn evpn" ] ]

    expect(result).to be_complete
    paths.each do |path|
      capture = parser.cursor.captures_for(path).fetch(0)
      expect(capture.data).to eq(result.records.first.dig(*path))
      expect(capture.block).to be_complete
    end
    expect(parser.cursor.captures_for(paths.first).first.content).to eq("  member vni 10110\n    ingress-replication protocol bgp\n    suppress-arp\n")
  end

  it "normalizes pure-CR configuration digests while preserving original source without a terminal newline" do
    source = "hostname LEAF\r! comment\r\rinterface Vlan10\r  description Users\r  ip address 10.0.10.1/24"
    result = parser.parse(source, complete: true)
    capture = parser.cursor.captures_for([ :interfaces, "Vlan10" ]).fetch(0)
    normalized = described_class.parse(source.tr("\r", "\n"), complete: true)

    expect(result).to be_complete
    expect(result.records).to eq(normalized.records)
    expect(capture.content).to eq("interface Vlan10\r  description Users\r  ip address 10.0.10.1/24")
    expect(capture.block.line_range).to eq(4..6)
    expect(parser.cursor.content).to eq(source)
  end

  it "records address-family source blocks for the flattened route targets and exports" do
    result = parser.parse(<<~CONFIG, complete: true)
      hostname LEAF
      vrf context BLUE
        address-family ipv4 unicast
          route-target both auto evpn
          export vrf default 100 map SHARED allow-vpn
    CONFIG

    [ [ :vrfs, "BLUE", :route_targets, 0 ], [ :vrfs, "BLUE", :exports, 0 ] ].each do |path|
      capture = parser.cursor.captures_for(path).fetch(0)
      expect(capture.data).to eq(result.records.first.dig(*path))
      expect(capture.block.line).to eq(3)
      expect(capture.content).to include("address-family ipv4 unicast\n", "export vrf default")
    end
  end

  it "keeps unsupported syntax distinct from recognized and unrelated lines" do
    result = parser.parse(<<~CONFIG, complete: true)
      hostname LEAF
      interface Vlan10
        description Users
        switchport
        ip address dhcp extra
      ! comment
      username admin password SECRET
    CONFIG

    expect(result.status).to eq(:partial)
    expect(result.issues).to include(code: :unsupported_configuration, line: 5)
    expect((0...parser.cursor.size).map { |index| parser.cursor.state(index) }).to eq(
      [ :parsed, :parsed, :parsed, :parsed, :unsupported, :ignored, :ignored ]
    )
    expect(parser.cursor.captures_for([ :interfaces, "Vlan10" ]).first.block).not_to be_complete
    expect(result.to_h.inspect).not_to include("SECRET")
    expect(parser.cursor.inspect).not_to include("SECRET")
    expect(parser.blocks.inspect).not_to include("SECRET")
  end

  it "marks an invalid child precisely and leaves subsequent unvisited children pending" do
    result = parser.parse(<<~CONFIG, complete: true)
      hostname LEAF
      interface Vlan10
        ip address 999.0.0.1/24
        description Not visited
      interface Ethernet1/1
        no shutdown
    CONFIG

    expect(result.issues).to include(code: :invalid_configuration_value, line: 2)
    expect(result.records.first[:interfaces]).not_to have_key("Vlan10")
    expect(parser.cursor.state(1)).to eq(:parsed)
    expect(parser.cursor.state(2)).to eq(:invalid)
    expect(parser.cursor.state(3)).to eq(:pending)
    expect(parser.cursor.state(5)).to eq(:parsed)
    expect(parser.cursor.captures_for([ :interfaces, "Vlan10" ])).to be_empty
  end

  it "rejects misplaced modeled syntax below an otherwise recognized leaf" do
    result = parser.parse("hostname LEAF\ninterface Vlan10\n  vrf member BLUE\n    ip address 10.0.10.1/24\n", complete: true)

    expect(result.status).to eq(:partial)
    expect(result.issues).to include(code: :unsupported_configuration, line: 4)
    expect(result.records.first[:interfaces]["Vlan10"]).to include(vrf: "BLUE", addresses: [])
    expect(parser.cursor.state(2)).to eq(:parsed)
    expect(parser.cursor.state(3)).to eq(:unsupported)
    expect(parser.cursor.captures_for([ :interfaces, "Vlan10" ]).first.block).not_to be_complete
  end

  it "invalidates both conflicting identity headers without claiming to parse the rejected block" do
    result = parser.parse("hostname LEAF\ninterface Vlan10\n  no shutdown\ninterface Vlan10\n  shutdown\n", complete: true)

    expect(result.records.first[:interfaces]).not_to have_key("Vlan10")
    expect(parser.cursor.state(1)).to eq(:invalid)
    expect(parser.cursor.state(3)).to eq(:invalid)
    expect(parser.cursor.state(4)).to eq(:pending)
    expect(parser.cursor.captures_for([ :interfaces, "Vlan10" ]).first.block).not_to be_complete
  end

  it "retains independent snapshots and resolves feature paths after sorting and deduplication" do
    result = parser.parse("hostname LEAF\nfeature ospf\nfeature bgp\nfeature ospf\ninterface Vlan10\n  description Users\n", complete: true)
    captures = parser.cursor.captures_for([ :features, 1 ])
    interface = parser.cursor.captures_for([ :interfaces, "Vlan10" ]).first

    expect(captures.map(&:data)).to eq([ "ospf", "ospf" ])
    expect(captures.map { |capture| capture.block.line }).to eq([ 2, 4 ])
    expect { result.records.first[:interfaces]["Vlan10"][:description].replace("Changed") }.to raise_error(FrozenError)
    expect(interface.data).not_to equal(result.records.first[:interfaces]["Vlan10"])
    expect(interface.data[:description]).to eq("Users")
    expect(interface.data).to be_frozen
    expect(interface.data[:description]).to be_frozen
  end

  it "isolates each invocation while allowing previous source captures to remain inspectable" do
    parser.parse("hostname OLD\ninterface Vlan10\n  description Before\n", complete: true)
    previous = parser.cursor
    parser.parse("hostname NEW\n", complete: true)

    expect(parser.cursor).not_to equal(previous)
    expect(parser.cursor.captures_for([ :interfaces, "Vlan10" ])).to be_empty
    expect(previous.captures_for([ :interfaces, "Vlan10" ]).first.content).to include("description Before")
    expect { parser.parse(nil, complete: true) }.to raise_error(ArgumentError)
    expect(parser.cursor).to be_nil
    expect(parser.blocks).to be_empty
  end
  it "does not infer complete configuration from inline paging in unmodeled lines" do
    result = described_class.parse("hostname LEAF\nlogging server 192.0.2.1--More--\n", complete: true)
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :incomplete_configuration, line: 2))
  end
end
