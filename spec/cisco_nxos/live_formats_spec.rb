# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe "NX-OS live table formats" do
  let(:parser) { Vxlan::RuntimeParser.new(platform: :cisco_nxos) }

  it "reads declared BGP route types without requiring a duplicated total column" do
    text = "BGP summary information for VRF default, address family L2VPN EVPN\n" \
      "Neighbor V AS MsgRcvd MsgSent TblVer InQ OutQ Up/Down State/PfxRcd\n192.0.2.1 4 65001 1 1 0 0 0 1d 10\n" \
      "Neighbor T AS Type-1 Type-2 Type-3 Type-4 Type-5 Type-6 Type-7 Type-8 Type-12\n192.0.2.1 I 65001 0 3 2 0 5 0 0 0 0\n"
    result = parser.parse(:bgp_neighbors, text, complete: true)
    expect(result).to be_complete
    expect(result.records.first[:prefixes_by_type]).to eq(type1: 0, type2: 3, type3: 2, type4: 0, type5: 5, type6: 0, type7: 0, type8: 0, type12: 0)
    [ text.sub("0 3 2 0 5", "0 30 2 0 5"), text.sub("Type-12", "Type-8"), text.sub("0 3 2 0 5", "0 3 2 0") ].each do |invalid|
      expect(parser.parse(:bgp_neighbors, invalid, complete: true)).not_to be_complete
    end
  end

  it "recognizes newer MAC and next-hop flag legends without ignoring unknown rows" do
    mac = "TL - True Learned, PS - Peer Sync, RO - Re-originate\nVLAN MAC Address Type age Secure NTFY Ports\n* 100 0200.0000.0001 dynamic NA F F Po1\n"
    route = "NH Flags- (Asy): Asymmetric VNI (RS): Remote Site Flag\n          (GU): Group Policy Unaware\n" \
      "Topology Mac Address Prod Flags Seq No Next-Hops\n100 0200.0000.0001 BGP Rcv 0 192.0.2.1\n"
    { mac_addresses: mac, l2route_macs: route }.each do |name, text|
      result = parser.parse(name, text, complete: true)
      expect(result).to be_complete
      expect(result.records.size).to eq(1)
      expect(parser.parse(name, text + "unknown row\n", complete: true)).not_to be_complete
    end
  end

  it "keeps an NVE peer with an explicitly unavailable router MAC" do
    text = "Interface Peer-IP State LearnType Uptime Router-Mac\nnve1 192.0.2.1 Up CP 2y45w n/a\n"
    result = parser.parse(:nve_peers, text, complete: true)
    expect(result).to be_complete
    expect(result.records).to eq([ { interface: "nve1", peer_address: "192.0.2.1", state: "up", learn_type: "CP", uptime: "2y45w", router_mac: nil } ])
    expect(parser.parse(:nve_peers, text.sub("n/a", "bad-mac"), complete: true)).not_to be_complete
  end

  it "accepts an empty optional CDP UUID without weakening neighbor identity" do
    text = "Device ID: LAB\nInterface: Ethernet1/1, Port ID (outgoing port): Ethernet1/2\nDC_UUID:\nTotal entries displayed: 1\n"
    result = parser.parse(:cdp_neighbors, text, complete: true)
    expect(result).to be_complete
    expect(result.records.first[:attributes]).to include(dc_uuid: nil)
    expect(parser.parse(:cdp_neighbors, text.sub("Ethernet1/2", ""), complete: true)).not_to be_complete
    [ "DC_UUID: KNOWN\nDC_UUID:\nDC_UUID: KNOWN", "DC_UUID:\nDC_UUID: KNOWN\nDC_UUID:" ].each do |declarations|
      result = parser.parse(:cdp_neighbors, text.sub("DC_UUID:", declarations), complete: true)
      expect(result).not_to be_complete
      expect(result.records.first[:attributes][:dc_uuid]).to be_nil
    end
  end

  it "retains starred down vPC members and their wrapped consistency reason" do
    text = <<~CLI
      vPC domain id: 1
      Peer status: peer adjacency formed ok
      vPC keep-alive status: peer is alive
      Configuration consistency status: success
      Number of vPCs configured: 3
      Id    Port          Status Consistency Reason                Active vlans
      30    Po30          down*  success     success               -
      40    Po40          down*  Not         Consistency Check Not -
                                 Applicable   Performed
      43    Po43          up     success     success               100,200
                                                                   ,300
    CLI
    result = parser.parse(:vpc, text, complete: true)
    expect(result).to be_complete
    members = result.records.first[:members]
    expect(members.size).to eq(3)
    expect(members[0]).to include(id: 30, state: "down", forwarding_via_peer_link: true)
    expect(members[1]).to include(id: 40, state: "down", consistency: "Not Applicable", reason: "Consistency Check Not Performed", active_vlans_summary: "-")
    expect(members[2]).to include(id: 43, state: "up", active_vlans_summary: "100,200,300")
    truncated = parser.parse(:vpc, text.sub(",300", ",300,  ..."), complete: true)
    expect(truncated).to be_complete
    expect(truncated.records.first[:members][2]).to include(active_vlans_summary: "100,200,300,  ...", active_vlans_truncated: true)
    expect(parser.parse(:vpc, text.lines.reject { |line| line.include?("Applicable") }.join, complete: true)).not_to be_complete
    expect(parser.parse(:vpc, text + "Applicable Performed\n", complete: true)).not_to be_complete
  end
end
