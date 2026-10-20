# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Vxlan::CiscoNxos::Parsers::ShowBgpL2vpnEvpnSummary do
  def parse(rows)
    described_class.parse("BGP summary information for VRF default, address family L2VPN EVPN\n" \
      "Neighbor V AS MsgRcvd MsgSent TblVer InQ OutQ Up/Down State/PfxRcd\n#{rows}", complete: true)
  end

  it "requires a known EVPN scope for nonempty neighbor evidence" do
    row = "Neighbor V AS MsgRcvd MsgSent TblVer InQ OutQ Up/Down State/PfxRcd\n192.0.2.1 4 65001 1 1 0 0 0 1d 5\n"
    [ "", "BGP summary information for VRF default, address family UNKNOWN\n" ].each do |scope|
      result = described_class.parse(scope + row, complete: true)
      expect(result.status).to eq(:partial)
      expect(result.records).to be_empty
    end
  end

  it "excludes a scope with contradictory router identities even after a repeated original value" do
    %w[router_id local_as].each do |field|
      first = "BGP router identifier 192.0.2.254, local AS number 65001\n"
      second = field == "router_id" ? first.sub("192.0.2.254", "192.0.2.253") : first.sub("65001", "65002")
      result = parse(first + "192.0.2.1 4 65001 1 1 0 0 0 1d 5\n" + second + first)
      expect(result.status).to eq(:partial)
      expect(result.records).to be_empty
      expect(result.issues).to include(include(code: :conflicting_bgp_identity))
    end
  end

  it "isolates conflicting logical scopes across repeated blocks including an empty block" do
    block = "BGP summary information for VRF default, address family L2VPN EVPN\n" \
      "BGP router identifier 192.0.2.254, local AS number 65001\n" \
      "Neighbor V AS MsgRcvd MsgSent TblVer InQ OutQ Up/Down State/PfxRcd\n192.0.2.1 4 65001 1 1 0 0 0 1d 5\n"
    other = block.sub("192.0.2.254", "192.0.2.253").sub("number 65001", "number 65002").sub("192.0.2.1 4", "192.0.2.2 4")
    empty = other.lines.first(2).join + "No BGP neighbors found\n"
    [ other, empty ].each do |conflict|
      result = described_class.parse(block + conflict + block.sub("VRF default", "VRF independent"), complete: true)
      expect(result.status).to eq(:partial)
      expect(result.records.map { |row| row[:vrf] }).to eq([ "independent" ])
      expect(result.issues).to include(include(code: :conflicting_bgp_identity))
    end
    expect(described_class.parse(block + other.sub("VRF default", "VRF independent"), complete: true)).to be_complete
  end

  it "validates ASPLAIN and ASDOT local identity without treating equivalent forms as conflicting" do
    row = "192.0.2.1 4 65001 1 1 0 0 0 1d 5\n"
    %w[0 4294967296 65536.1 1.65536 0.0].each do |asn|
      result = parse("BGP router identifier 192.0.2.254, local AS number #{asn}\n" + row)
      expect(result.status).to eq(:partial)
      expect(result.records).to be_empty
    end
    result = parse("BGP router identifier 192.0.2.254, local AS number 65537\n" \
      "BGP router identifier 192.0.2.254, local AS number 1.1\n" + row)
    expect(result).to be_complete
  end

  it "excludes equivalent IPv6 neighbor identities instead of reporting conflicting states as complete" do
    result = parse("2001:db8::1 4 65001 1 1 0 0 0 1d 5\n" \
      "2001:db8:0:0::1 4 65002 1 1 0 0 0 1d Active\n")

    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :duplicate_identity))
    expect(result.records).to be_empty
  end

  it "joins prefix statistics to the normalized IPv6 identity" do
    [ [ "2001:0DB8:0:0::1", "2001:db8::1" ], [ "2001:db8::1", "2001:0DB8:0:0::1" ] ].each do |neighbor, statistics|
      result = parse("#{neighbor} 4 65001 1 1 0 0 0 1d 5\n" \
        "Neighbor T AS PfxRcd Type-2 Type-3 Type-4 Type-5\n" \
        "#{statistics} I 65001 5 2 1 0 2\n")

      expect(result).to be_complete
      expect(result.records.first).to include(peer_ip: "2001:db8::1", prefixes_by_type: { type2: 2, type3: 1, type4: 0, type5: 2 })
    end
  end

  it "keeps an invalid statistics address partial without raising" do
    result = parse("2001:db8::1 4 65001 1 1 0 0 0 1d 5\n" \
      "Neighbor T AS PfxRcd Type-2 Type-3 Type-4 Type-5\n" \
      "invalid I 65001 5 2 1 0 2\n")

    expect(result.status).to eq(:partial)
    expect(result.records.first).not_to have_key(:prefixes_by_type)
  end
end
