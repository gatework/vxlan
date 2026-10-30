# frozen_string_literal: true

require_relative "spec_helper"
require "vxlan/observation"
require "vxlan/collector"
require "vxlan/runtime_parser"

RSpec.describe Vxlan::RuntimeParser do
  subject(:parser) { described_class.new(platform: :cisco_nxos) }

  def parse(name, text, complete: true)
    parser.parse(name, text, complete: complete)
  end

  def fixture(name)
    File.read(File.expand_path("fixtures/netstack/#{name}.txt", __dir__))
  end

  it "rejects inline pagination and terminal controls even in free-form descriptions" do
    [ "--More--", "-- More --", "hello\0world", "hello\e[31mworld", "hello\bworld" ].each do |description|
      result = parse(:interfaces, "Interface Status Description\nLo0 up #{description}\nLo1 up SAFE\n")
      expect(result.status).to eq(:partial)
      expect(result.issues).to include(include(code: :invalid_terminal_output, line: 2))
      expect(result.records).to be_empty
    end
    expect(parse(:interfaces, "--\nMore\n--\n").status).to eq(:partial)
  end

  it "rejects bare carriage returns before they can join authoritative runtime fields" do
    source = "Interface Status Description\nLo0 up SAFE\n"
    [ source.sub("Lo0", "Lo\r0"), source.sub("SAFE", "SA\rFE"), source.sub("SAFE\n", "SAFE\r") ].each do |output|
      result = parse(:interfaces, output)
      expect(result.status).to eq(:partial)
      expect(result.records).to be_empty
      expect(result.issues).to include(include(code: :invalid_terminal_output, line: 2))
    end
    crlf = parse(:interfaces, source.gsub("\n", "\r\n"))
    expect(crlf).to be_complete
    expect(crlf.records).to eq(parse(:interfaces, source).records)
  end

  it "removes conflicting port-channel members including wrapped aliases" do
    header = "Group Port- Type Protocol Member Ports\n"
    [ "10 Po10(SU) Eth LACP Eth1/1(P) Eth1/1(D) Eth1/2(P)\n",
      "10 Po10(SU) Eth LACP Eth1/1(P) Eth1/2(P)\n  Ethernet1/1(D)\n" ].each do |rows|
      result = parse(:port_channels, header + rows)
      expect(result.status).to eq(:partial)
      expect(result.records.first[:members]).to eq([ { interface: "Eth1/2", flags: "P" } ])
      expect(result.issues).to include(include(code: :duplicate_identity))
    end
  end

  it "does not attach port-channel continuations across invalid rows or table boundaries" do
    header = "Group Port- Type Protocol Member Ports\n"
    [ "broken row\n", header, "Number of port-channels: 1\n", "Eth1/3(P) malformed\n" ].each do |boundary|
      result = parse(:port_channels, header + "10 Po10(SU) Eth LACP Eth1/1(P)\n" + boundary + "  Eth1/2(P)\n")
      expect(result.status).to eq(:partial)
      expect(result.records.first[:members]).to eq([ { interface: "Eth1/1", flags: "P" } ])
    end
  end

  it "does not assign the same physical member to two port channels" do
    result = parse(:port_channels, "Group Port- Type Protocol Member Ports\n" \
      "10 Po10(SU) Eth LACP Eth1/1(P) Eth1/2(P)\n20 Po20(SU) Eth LACP Ethernet1/1(P) Eth1/3(P)\n")
    expect(result.status).to eq(:partial)
    expect(result.records.map { |row| row[:members].map { |member| member[:interface] } }).to eq([ [ "Eth1/2" ], [ "Eth1/3" ] ])
  end

  let(:bgp) do
    <<~TEXT
      BGP summary information for VRF default, address family L2VPN EVPN
      BGP router identifier 192.0.2.1, local AS number 65001
      BGP table version is 123, L2VPN EVPN config peers 1, capable peers 1
      Neighbor V AS MsgRcvd MsgSent TblVer InQ OutQ Up/Down State/PfxRcd
      192.0.2.2 4 65002 10 20 123 0 0 1d 12
      Neighbor T AS PfxRcd Type-2 Type-3 Type-4 Type-5 Type-12
      192.0.2.2 I 65002 12 5 4 0 3 0
    TEXT
  end

  let(:ospf) do
    <<~TEXT
      OSPF Process ID UNDERLAY VRF default
      Total number of neighbors: 1
      Neighbor ID Pri State Up Time Address Interface
      192.0.2.2 1 FULL/ - 1d 192.0.2.3 Eth1/1
    TEXT
  end

  let(:cdp) do
    <<~TEXT
      Device ID: SPINE.example.test(SERIAL)
      System Name: SPINE
      Interface address(es): 1
      IPv4 Address: 192.0.2.2
      Platform: N9K, Capabilities: Router Switch
      Interface: Ethernet1/1, Port ID (outgoing port): Ethernet1/2
      Version:
      Software description: legacy feature not supported
      Second software line
      Advertisement Version: 2
      Mgmt address(es):
      IPv4 Address: 198.51.100.2
      Duplex: full
      MTU: 9216
      Native VLAN: 40
      Total cdp entries displayed : 1
    TEXT
  end

  let(:vpc) do
    <<~TEXT
      Legend:
      (*) - local vPC is down, forwarding via vPC peer-link
      vPC domain id : 7
      Peer status : peer adjacency formed ok
      vPC keep-alive status : peer is alive
      Configuration consistency status : success
      Number of vPCs configured : 1
      vPC Peer-link status
      id Port Status Active vlans
      1 Po100 up 110,120
      vPC status
      Id Port Status Consistency Reason Active vlans
      10 Po10 up success  success  110,120
    TEXT
  end

  let(:outputs) do
    {
      cdp_neighbors: cdp, bgp_neighbors: bgp, ospf_neighbors: ospf, vpc: vpc,
      nve_peers: "Interface Peer-IP State LearnType Uptime Router-Mac\nnve1 192.0.2.2 Up CP 1d 0011.2233.4455\n",
      nve_vnis: "Interface VNI Multicast-group State Mode Type [BD/VRF] Flags\nnve1 10110 UnicastBGP Up CP L2 [110] SA\n",
      interfaces: "Interface Status Description\nLo0 up underlay router\n",
      port_channels: "Group Port-Channel Type Protocol Member Ports\n10 Po10(SU) Eth LACP Eth1/1(P) Eth1/2(D)\n",
      mac_addresses: "VLAN MAC Address Type age Secure NTFY Ports\n* 110 0011.2233.4455 dynamic 0 F F nve1(192.0.2.2)\n",
      l2route_macs: fixture(:l2route_macs), l2route_mac_ips: fixture(:l2route_mac_ips)
    }
  end

  %i[cdp_neighbors nve_peers nve_vnis bgp_neighbors ospf_neighbors vpc interfaces port_channels mac_addresses l2route_macs l2route_mac_ips].each do |name|
    it "retains #{name} rows but withholds completeness after transport truncation or unknown output" do
      complete = parse(name, outputs.fetch(name))
      expect(complete).to be_complete, complete.issues.inspect
      expect(complete.records).not_to be_empty
      partial = parse(name, outputs.fetch(name), complete: false)
      expect(partial.status).to eq(:partial)
      expect(partial.records).to eq(complete.records)
      expect(parse(name, outputs.fetch(name) + "unrecognized firmware field\n").status).to eq(:partial)
      expect(parse(name, "").status).to eq(:partial)
      expect(parse(name, "% Invalid command at '^' marker.\n").status).to eq(:unsupported)
    end
  end

  it "requires dimension-specific empty evidence before a complete empty observation" do
    { nve_peers: "No peers found", nve_vnis: "No VNIs found", bgp_neighbors: "No BGP neighbors found",
      ospf_neighbors: "Total number of neighbors: 0", cdp_neighbors: "Total cdp entries displayed : 0",
      interfaces: "0 interfaces", port_channels: "Number of port-channels: 0", mac_addresses: "No entries found",
      l2route_macs: "No routes found", l2route_mac_ips: "Total number of routes: 0" }.each do |name, empty|
      expect(parse(name, empty)).to be_complete
      expect(parse(name, empty).records).to be_empty
      expect(parse(name, outputs.fetch(name) + empty).status).to eq(:partial)
    end
    expect(parse(:nve_peers, "No interfaces found").status).to eq(:partial)
    %i[nve_peers nve_vnis interfaces port_channels mac_addresses l2route_macs l2route_mac_ips].each do |name|
      header = outputs.fetch(name).lines.find { |line| line.match?(/\A(?:Interface|Group|VLAN|Topology)\b/) }
      expect(parse(name, header).status).to eq(:partial)
    end
  end

  it "parses binary transport bytes as UTF-8 without replacing invalid bytes or mutating the source" do
    text = ("(NA)- Not Applicable A – ESI Active Path, S – ESI Standby Path\n" + outputs[:mac_addresses]).b.freeze
    observation = parse(:mac_addresses, text)
    expect(observation).to be_complete
    expect(observation.records).to eq(parse(:mac_addresses, outputs[:mac_addresses]).records)
    expect(text.encoding).to eq(Encoding::BINARY)
    [ text + "\xFF".b, "\xFF".b.force_encoding(Encoding::UTF_8) ].each do |invalid|
      result = parse(:mac_addresses, invalid)
      expect(result.status).to eq(:partial)
      expect(result.issues).to include(code: :invalid_encoding)
      expect(result.records).to be_empty
    end
  end

  it "does not choose a winner for conflicting identities" do
    %i[nve_peers nve_vnis interfaces port_channels mac_addresses cdp_neighbors].each do |name|
      observation = parse(name, outputs.fetch(name) * 2)
      expect(observation.status).to eq(:partial)
      expect(observation.records).to be_empty
      expect(observation.issues.map { |issue| issue[:code] }).to include(:duplicate_identity)
    end
  end

  it "recovers only complete known NVE line wrapping and preserves spaced legends" do
    wrapped = outputs[:nve_peers].sub("Router-Mac", "Route\nr-Mac").sub("0011.2233.4455", "0011.\n2233.4455")
    expect(parse(:nve_peers, wrapped).records.first[:router_mac]).to eq("0011.2233.4455")
    expect(parse(:nve_peers, wrapped)).to be_complete
    expect(parse(:nve_peers, wrapped.sub("2233.4455", "2233.445")).status).to eq(:partial)
    legends = "Codes: CP - Control Plane        DP - Data Plane\nUC - Unconfigured      SA - Suppress ARP\nS-ND - Suppress ND\n"
    expect(parse(:nve_vnis, legends + outputs[:nve_vnis])).to be_complete
    expect(parse(:nve_vnis, outputs[:nve_vnis].sub(" SA", " UNKNOWN")).status).to eq(:partial)
    expect(parse(:nve_vnis, outputs[:nve_vnis].sub("10110", "16777216")).records).to be_empty
    expect(parse(:nve_peers, outputs[:nve_peers].sub("192.0.2.2", "300.0.2.2")).records).to be_empty
  end

  it "keeps BGP counters and per-VRF prefix statistics attached to the right neighbor" do
    result = parse(:bgp_neighbors, bgp + bgp.sub("VRF default", "VRF BLUE"))
    expect(result).to be_complete, result.issues.inspect
    expect(result.records.map { |row| row[:vrf] }).to eq(%w[default BLUE])
    expect(result.records.first).to include(remote_as: 65002, received_prefixes: 12, state: :established,
      prefixes_by_type: { type2: 5, type3: 4, type4: 0, type5: 3, type12: 0 })
    empty_scope = "BGP summary information for VRF GREEN, address family L2VPN EVPN\nNo BGP neighbors found\n"
    expect(parse(:bgp_neighbors, bgp + empty_scope)).to be_complete
  end

  it "rejects missing, repeated, inconsistent and unknown BGP prefix statistics" do
    statistics = bgp.lines.last
    invalid = [ bgp.delete_suffix(statistics), bgp + statistics, bgp.sub("I 65002 12", "I 65002 13"),
      bgp.sub("I 65002", "Z 65002"), bgp.sub("Type-12", "Type-99"), bgp.sub("5 4 0 3 0", "5 4 0 3") ]
    invalid.each { |text| expect(parse(:bgp_neighbors, text).status).to eq(:partial) }
    expect(parse(:bgp_neighbors, bgp + "BGP attribute entries [broken]\n").status).to eq(:partial)
    expect(parse(:bgp_neighbors, bgp.sub("State/PfxRcd", "State/\nPfxRcd"))).to be_complete
  end

  it "keeps zero-prefix BGP established and administrative idle distinct" do
    text = bgp.lines.take(5).join.sub("1d 12", "1d 0")
    expect(parse(:bgp_neighbors, text).records.first).to include(state: :established, received_prefixes: 0)
    expect(parse(:bgp_neighbors, text.sub("1d 0", "1d Idle (Admin)")).records.first).to include(state: :shutdown, received_prefixes: nil)
  end

  it "checks OSPF totals separately for each process and VRF" do
    second = ospf.sub("UNDERLAY VRF default", "TENANT VRF BLUE")
    expect(parse(:ospf_neighbors, ospf + second)).to be_complete
    wrong = ospf.sub("neighbors: 1", "neighbors: 0") + second.sub("neighbors: 1", "neighbors: 2")
    expect(parse(:ospf_neighbors, wrong).status).to eq(:partial)
    empty = "OSPF Process ID EMPTY VRF GREEN\nTotal number of neighbors: 0\n"
    expect(parse(:ospf_neighbors, ospf + empty)).to be_complete
    expect(parse(:ospf_neighbors, ospf).records.first[:state]).to eq(:full)
  end

  it "binds interface columns to their headers and keeps state words in descriptions" do
    text = <<~TEXT
      Port VRF Status IP Address Speed MTU
      mgmt0 management up 192.0.2.1 1000 1500
      Ethernet VLAN Type Mode Status Reason Speed Port
      Interface Ch #
      Eth1/1 -- eth routed down XCVR not inserted auto(D) --
      Port-channel VLAN Type Mode Status Reason Speed Protocol
      Po101 40 eth trunk up none 25G(D) LACP
      Interface Status Description
      Lo0 up backup down interface
      Interface Secondary VLAN(Type) Status Reason
      Vlan40 -- down Administratively down
      Port Status Reason MTU
      nve1 up none 9216
      Port Name Status Vlan Duplex Speed Type
      Eth1/2 backup up link down routed full 10G 10Gbase-SR
    TEXT
    observation = parse(:interfaces, text)
    expect(observation).to be_complete, observation.issues.inspect
    rows = observation.records.to_h { |row| [ row[:interface], row ] }
    expect(rows["mgmt0"]).to include(vrf: "management", mtu: 1500)
    expect(rows["Eth1/1"][:reason]).to eq("XCVR not inserted")
    expect(rows["Lo0"][:description]).to eq("backup down interface")
    expect(rows["Eth1/2"]).to include(name: "backup up link", state: "down", vlan: "routed")
    expect(parse(:interfaces, text.sub("1000 1500", "1000 broken")).status).to eq(:partial)
    expect(parse(:interfaces, text.sub("Status IP Address", "Status Unknown")).status).to eq(:partial)
  end

  it "retains wrapped port-channel members, empty groups and routed MAC destinations" do
    ports = "Group Port- Type Protocol Member Ports\nChannel\n100 Po100(SD) Eth NONE --\n101 Po101(SU) Eth LACP Eth1/1(P)\n  Eth1/2(P)\n"
    observation = parse(:port_channels, ports)
    expect(observation).to be_complete
    expect(observation.records.first[:members]).to be_empty
    expect(observation.records.last[:members].map { |row| row[:interface] }).to eq(%w[Eth1/1 Eth1/2])
    expect(parse(:port_channels, "Eth1/2(P)\n").status).to eq(:partial)
    mac = "VLAN MAC Address Type age Secure NTFY Ports\n----+----+----\nG - 0011.2233.4455 static - F F Lo0(R) (Lo0)\n"
    expect(parse(:mac_addresses, mac)).to be_complete
    expect(parse(:mac_addresses, mac).records.first).to include(vlan_id: nil, destination: "Lo0(R) (Lo0)")
  end

  it "separates explicitly routed local gateway MACs from forwarding identities" do
    text = <<~TEXT
      VLAN MAC Address Type age Secure NTFY Ports
      G - 0011.2233.4455 static - F F sup-eth1(R)
      G - 0011.2233.4455 static - F F Lo0(R) (Lo0)
      * 999 aabb.ccdd.eeff static - F F Vlan999
      G 999 aabb.ccdd.eeff static - F F sup-eth1(R)
    TEXT
    result = parse(:mac_addresses, text)
    expect(result).to be_complete
    expect(result.records.size).to eq(4)
    expect(result.records.map { |row| row[:flags] }).to eq([ "G", "G", "*", "G" ])
    repeated = parse(:mac_addresses, text + text.lines.last)
    expect(repeated.status).to eq(:partial)
    expect(repeated.records.size).to eq(3)
    expect(repeated.issues).to include(code: :duplicate_identity, count: 1)

    forwarding = "VLAN MAC Address Type age Secure NTFY Ports\n* 110 0011.2233.4455 dynamic 0 F F Eth1/1\n"
    [ forwarding.lines.last.sub("Eth1/1", "Eth1/2"), forwarding.lines.last.sub("dynamic", "static") ].each do |conflict|
      observation = parse(:mac_addresses, forwarding + conflict)
      expect(observation.status).to eq(:partial)
      expect(observation.records).to be_empty
    end
    unmarked = text.sub("G -", "* -").sub("G -", "* -")
    expect(parse(:mac_addresses, unmarked).status).to eq(:partial)
    expect(parse(:mac_addresses, text.gsub("static", "dynamic")).status).to eq(:partial)
  end

  it "rejects malformed vPC identities, unsupported fields and mismatched member totals" do
    expect(parse(:vpc, vpc).records.first[:members].first).to include(id: 10, reason: "success", active_vlans_summary: "110,120")
    [ vpc.sub("id : 7", "id : unknown"), vpc.sub("configured : 1", "configured : 2"),
      vpc + "New setting: value\n", vpc + vpc.lines.last ].each do |text|
      expect(parse(:vpc, text).status).to eq(:partial)
    end
  end

  it "preserves CDP address scopes and software metadata while checking the trailing count" do
    result = parse(:cdp_neighbors, cdp)
    expect(result).to be_complete
    expect(result.records.first).to include(remote_name: "SPINE", interface_addresses: [ "192.0.2.2" ],
      management_addresses: [ "198.51.100.2" ], remote_interface: "Ethernet1/2",
      version: "Software description: legacy feature not supported\nSecond software line",
      attributes: { advertisement_version: "2", duplex: "full", mtu: "9216", native_vlan: "40" })
    expect(parse(:cdp_neighbors, cdp.sub("displayed : 1", "displayed : 2")).status).to eq(:partial)
    expect(parse(:cdp_neighbors, cdp.lines.reject { |line| line.start_with?("Interface:") }.join).records).to be_empty
    expect(parse(:cdp_neighbors, cdp.sub("198.51.100.2", "300.51.100.2")).status).to eq(:partial)
    expect(parse(:cdp_neighbors, cdp.sub("Second software line", "--More--")).status).to eq(:partial)
    expect(parse(:cdp_neighbors, cdp.sub("Second software line", "--------\nunknown field")).status).to eq(:partial)
  end

  it "retains NX-OS CDP location, interface MACs and device UUID in neighbor attributes" do
    metadata = <<~TEXT
      Physical Location: `
      Local Interface MAC: 00:11:22:33:44:55
      Remote Interface MAC: AA:BB:CC:DD:EE:FF
      DC_UUID: EXAMPLE1234
    TEXT
    text = cdp.sub("Total cdp entries", metadata + "Total cdp entries")
    result = parse(:cdp_neighbors, text)
    expect(result).to be_complete
    expect(result.records.first[:attributes]).to include(physical_location: "`", local_interface_mac: "00:11:22:33:44:55",
      remote_interface_mac: "aa:bb:cc:dd:ee:ff", dc_uuid: "EXAMPLE1234")
    [ text.sub("00:11:22:33:44:55", "malformed"), text + "Unknown Location: rack\n" ].each do |invalid|
      expect(parse(:cdp_neighbors, invalid).status).to eq(:partial)
    end
  end

  it "retains L2RIB topology, producer, multiple addresses, ECMP and optional legacy columns" do
    macs = parse(:l2route_macs, fixture(:l2route_macs))
    expect(macs.records.first).to include(topology_id: 8, mac: "00:11:22:33:44:55", producer: "BGP",
      next_hops: [ { address: "192.0.2.21", label: 100008 }, { address: "192.0.2.22", label: 100008 } ])
    ips = parse(:l2route_mac_ips, fixture(:l2route_mac_ips))
    expect(ips.records.map { |row| row[:host_ip] }).to eq(%w[192.0.2.11 192.0.2.12 2001:db8::11])
    legacy = parse(:l2route_mac_ips, "Topology ID Mac Address Prod Host IP Next Hop (s)\n8 0011.2233.4455 HMM 192.0.2.11 Local\n")
    expect(legacy).to be_complete
    expect(legacy.records.first).not_to have_key(:sequence)
    expect(legacy.records.first[:next_hops]).to eq([ { local: true } ])
    ifindex = parse(:l2route_macs, "Topology Mac Address Prod Next Hop (s)\n8 0011.2233.4455 Local Ifindex   4362086\n")
    expect(ifindex).to be_complete
    expect(ifindex.records.first[:next_hops]).to eq([ { ifindex: 4362086 } ])
  end

  it "drops ambiguous duplicate L2RIB identities while preserving unrelated routes" do
    text = fixture(:l2route_mac_ips)
    result = parse(:l2route_mac_ips, text + text.lines[-3].sub("192.0.2.21", "192.0.2.99"))
    expect(result.status).to eq(:partial)
    expect(result.records.map { |row| row[:host_ip] }).to eq(%w[192.0.2.12 2001:db8::11])
    expect(result.issues.map { |issue| issue[:code] }).to include(:duplicate_identity)
  end

  it "rejects malformed L2RIB addresses, labels, sequences and unfinished next-hop lists" do
    source = fixture(:l2route_mac_ips)
    invalid = [ source.sub("192.0.2.11 ", "300.0.2.11 "), source.sub("192.0.2.11 ", "192.0.2.0/24 "),
      source.sub("(Label: 100008)", "(Label:"), source.sub("(Label: 100008)", "(Label: 4294967296)"),
      source.sub("BGP    --            0", "BGP    --            broken"),
      source.sub("(Label: 100008)", "(Label: 100008),") ]
    invalid.each do |text|
      result = parse(:l2route_mac_ips, text)
      expect(result.status).to eq(:partial)
      expect(result.records.size).to eq(2)
    end
    expect(parse(:l2route_mac_ips, source + "Total number of routes: 4\n").status).to eq(:partial)
  end
end
