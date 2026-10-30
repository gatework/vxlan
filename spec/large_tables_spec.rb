# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "Large VXLAN tables" do
  it "joins reverse-ordered BGP statistics within each VRF and rejects repeated statistics" do
    peers = (1..128).map { |index| "192.0.2.#{index}" }
    output = %w[BLUE GREEN].map do |vrf|
      "BGP summary information for VRF #{vrf}, address family L2VPN EVPN\n" +
        "Neighbor V AS MsgRcvd MsgSent TblVer InQ OutQ Up/Down State/PfxRcd\n" +
        peers.each_with_index.map { |peer, index| "#{peer} 4 65001 0 0 0 0 0 1d #{index}\n" }.join +
        "Neighbor T AS PfxRcd Type-2 Type-3 Type-4 Type-5\n" +
        peers.each_with_index.map { |peer, index| "#{peer} I 65001 #{index} #{index} 0 0 0\n" }.reverse.join
    end.join
    parser = Vxlan::RuntimeParser.new(platform: :cisco_nxos)
    observation = parser.parse(:bgp_neighbors, output, complete: true)
    expect(observation).to be_complete
    expect(observation.records.size).to eq(256)
    observation.records.each do |row|
      expect(row[:prefixes_by_type][:type2]).to eq(row[:peer_address].split(".").last.to_i - 1)
    end
    expect(parser.parse(:bgp_neighbors, output + output.lines.last, complete: true).status).to eq(:partial)
    duplicate = output.sub("Neighbor T AS", "192.0.2.1 4 65001 0 0 0 0 0 1d 0\nNeighbor T AS")
    ambiguous = parser.parse(:bgp_neighbors, duplicate, complete: true)
    expect(ambiguous.status).to eq(:partial)
    expect(ambiguous.records).not_to include(include(vrf: "BLUE", peer_address: "192.0.2.1"))
    expect(ambiguous.records).to include(include(vrf: "GREEN", peer_address: "192.0.2.1"))
  end

  it "deduplicates wrapped next hops in source order without joining across invalid rows or headers" do
    header = "Topology Mac Address Prod Next Hop (s)\n"
    hops = (1..200).map { |index| "192.0.2.#{index}" }
    route = "8 0011.2233.4455 BGP #{hops.first} #{hops.first}\n"
    continuation = hops.reverse.map { |hop| "  #{hop} (Label: 100008), #{hop}\n" }.join
    output = header + route + continuation + "  malformed-hop\n  198.51.100.1\n" + header + "  198.51.100.2\n"
    observation = Vxlan::RuntimeParser.new(platform: :cisco_nxos).parse(:l2route_macs, output, complete: true)
    expect(observation.status).to eq(:partial)
    expected = [ { address: hops.first } ] + hops.reverse.flat_map do |hop|
      [ { address: hop, label: 100_008 }, { address: hop } ]
    end
    expect(observation.records.first[:next_hops]).to eq(expected.uniq)
    expect(observation.issues.count { |issue| issue[:code] == :unparsed_row }).to eq(3)
  end

  it "parses long inline next-hop lists and rejects malformed separators atomically" do
    hops = (1..1024).map { |index| "10.0.#{index / 256}.#{index % 256}" }
    header = "Topology Mac Address Prod Next Hop (s)\n"
    prefix = "8 0011.2233.4455 BGP "
    values = hops.map { |hop| "#{hop} (Label: 100008)" }.join(", ")
    parser = Vxlan::RuntimeParser.new(platform: :cisco_nxos)
    result = parser.parse(:l2route_macs, header + prefix + values + "\n", complete: true)
    expect(result).to be_complete
    expect(result.records.first[:next_hops]).to eq(hops.map { |hop| { address: hop, label: 100_008 } })
    [ values + ",", values + ",, Local", values + " malformed-hop", values + "Local" ].each do |invalid|
      result = parser.parse(:l2route_macs, header + prefix + invalid + "\n", complete: true)
      expect(result.status).to eq(:partial)
      expect(result.records).to be_empty
      expect(result.issues).to include(include(code: :unparsed_row, line: 2))
    end
  end

  it "keeps reference order, selectors, deduplication and independent binding arrays" do
    entries = (1..256).to_a.reverse.map do |sequence|
      { sequence: sequence, action: "permit", prefix_list_matches: [
        { address_family: "ipv4", selector: "address", names: %w[P P] },
        { address_family: "ipv4", selector: "next-hop", names: [ "P" ] },
        { address_family: "ipv6", selector: "address", names: [ "V6" ] }
      ] }
    end
    configuration = { route_maps: { "POLICY" => entries + [ entries.first ] }, bgp: {}, ospf: {},
      vrfs: { "BLUE" => { exports: [ { route_map: "POLICY", address_family: "ipv4 unicast", vrf: "default" } ] } } }
    resolver = Vxlan::PrefixListReferences.new(configuration)
    references = resolver.call.fetch("P")
    expect(references.map { |reference| [ reference[:sequence], reference[:selector] ] }).to eq(
      (1..256).flat_map { |sequence| [ [ sequence, nil ], [ sequence, "next-hop" ] ] })
    references.first[:bindings].clear
    expect(references[1][:bindings].size).to eq(1)
    expect(resolver.call.fetch("P").first[:bindings].size).to eq(1)
    expect(resolver.call(address_family: "ipv6").fetch("V6").size).to eq(256)
    configuration[:vrfs].clear
    expect(resolver.call.fetch("P").first[:bindings]).to be_empty
  end
end
