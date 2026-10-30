# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Vxlan::CiscoNxos::Parsers::ShowBgpL2vpnEvpnSummary do
  def parse(rows)
    described_class.parse("BGP summary information for VRF default, address family L2VPN EVPN\n" \
      "Neighbor V AS MsgRcvd MsgSent TblVer InQ OutQ Up/Down State/PfxRcd\n#{rows}", complete: true)
  end

  def counts(configured, capable)
    "BGP table version is 10, L2VPN EVPN config peers #{configured}, capable peers #{capable}\n"
  end

  let(:established) { "192.0.2.1 4 65001 1 1 10 0 0 1d 5\n" }
  let(:idle) { "192.0.2.2 4 65002 0 0 0 0 0 1d Idle\n" }
  let(:statistics) do
    "Neighbor T AS PfxRcd Type-2 Type-3\n" \
      "192.0.2.1 I 65001 5 2 3\n" \
      "192.0.2.2 E 65002 Idle 0 0\n"
  end

  it "checks declared configured peers without treating capable peers as the row count" do
    expect(parse(counts(2, 1) + established + idle)).to be_complete
    [ 0, 1, 3 ].each do |configured|
      result = parse(counts(configured, 0) + established + idle)
      expect(result.status).to eq(:partial)
      expect(result.records.size).to eq(2)
      expect(result.issues).to include(include(code: :count_mismatch, expected: configured, observed: 2))
    end
  end

  it "retains contradictory declarations even when the original count returns" do
    [ counts(1, 1), counts(2, 0), counts(2, 3) ].each do |conflict|
      result = parse(counts(2, 1) + conflict + counts(2, 1) + established + idle)
      expect(result.status).to eq(:partial)
      expect(result.records.size).to eq(2)
      expect(result.issues).to include(include(code: :conflicting_peer_counts))
    end
    impossible = parse(counts(2, 3) + established + idle)
    expect(impossible.issues).to include(include(code: :invalid_peer_counts, configured: 2, capable: 3))
  end

  it "accepts explicit zero peers but never lets another scope hide a missing neighbor" do
    expect(parse(counts(0, 0))).to be_complete
    expect(parse(counts(0, 0)).records).to be_empty
    scope = "BGP summary information for VRF default, address family L2VPN EVPN\n"
    header = "Neighbor V AS MsgRcvd MsgSent TblVer InQ OutQ Up/Down State/PfxRcd\n"
    first = scope + counts(2, 1) + header + established
    second = scope.sub("default", "BLUE") + counts(0, 0) + header
    result = described_class.parse(first + second, complete: true)
    expect(result.status).to eq(:partial)
    expect(result.records.map { |row| row[:vrf] }).to eq([ "default" ])
    expect(result.issues).to include(include(code: :count_mismatch, expected: 2, observed: 1))
    expect(described_class.parse(second, complete: false).status).to eq(:partial)
  end

  it "retains administrative shutdown and unknown AS without inventing an established session" do
    shutdown = idle.sub("Idle", "Shut (Admin)")
    result = parse(counts(2, 1) + established + shutdown)
    expect(result).to be_complete
    expect(result.records.last).to include(state: :shutdown, remote_as: 65002, received_prefixes: nil)
    unknown = parse(counts(1, 0) + idle.sub("4 65002", "4 0"))
    expect(unknown).to be_complete
    expect(unknown.records.first).to include(remote_as: nil, state: :idle, received_prefixes: nil)
    [ established.sub("4 65001", "4 0"), established.sub("4 65001", "4 4294967296"), idle.sub("4 65002", "4 4294967296") ].each do |row|
      invalid = parse(counts(1, 0) + row)
      expect(invalid.status).to eq(:partial)
      expect(invalid.records).to be_empty
    end
  end

  it "recognizes documented soft reconfiguration and dampening summaries only when well formed" do
    decorations = "12 received paths for inbound soft reconfiguration\n" \
      "12 identical, 0 modified, 0 filtered received paths using 0 bytes\n" \
      "Dampening configured, 0 history paths, 2 dampened paths\n"
    expect(parse(counts(1, 1) + decorations + established)).to be_complete
    [ decorations.sub("12 identical", "unknown identical"), decorations.sub("2 dampened", "-2 dampened") ].each do |invalid|
      expect(parse(counts(1, 1) + invalid + established).status).to eq(:partial)
    end
  end

  it "joins state-valued prefix statistics without converting an unknown total to zero" do
    [ "Idle", "Idle (Admin)", "Shut (Admin)" ].each do |state|
      result = parse(counts(2, 1) + established + idle.sub("Idle", state) + statistics.sub("Idle", state))
      expect(result).to be_complete, result.issues.inspect
      expect(result.records.last).to include(received_prefixes: nil, prefixes_by_type: { type2: 0, type3: 0 })
      expect(result.records.last[:state]).not_to eq("established")
    end
    unknown = (idle + statistics).gsub("65002", "0").sub("Idle 0 0", "Idle 2 1")
    result = parse(counts(2, 1) + established + unknown)
    expect(result).to be_complete
    expect(result.records.last).to include(remote_as: nil, received_prefixes: nil, prefixes_by_type: { type2: 2, type3: 1 })
  end

  it "rejects inconsistent state statistics while retaining the independently parsed neighbor" do
    [ statistics.sub("Idle 0 0", "Active 0 0"), statistics.sub("Idle 0 0", "0 0 0"),
      statistics.sub("E 65002", "E 0"), statistics.sub("Idle 0 0", "Idle 0"), statistics + statistics.lines.last,
      statistics.delete_suffix(statistics.lines.last) ].each do |invalid|
      result = parse(counts(2, 1) + established + idle + invalid)
      expect(result.status).to eq(:partial)
      expect(result.records.last).to include(state: :idle, received_prefixes: nil)
    end
  end

  it "accepts type statistics without a total column while preserving unknown prefix totals" do
    types = "Neighbor T AS Type-2 Type-3\n192.0.2.1 I 65001 2 3\n192.0.2.2 E 65002 0 0\n"
    result = parse(counts(2, 1) + established + idle + types)
    expect(result).to be_complete
    expect(result.records.last).to include(received_prefixes: nil, state: :idle, prefixes_by_type: { type2: 0, type3: 0 })
  end

  it "does not forget missing prefix statistics when a repeated neighbor header follows" do
    header = "Neighbor V AS MsgRcvd MsgSent TblVer InQ OutQ Up/Down State/PfxRcd\n"
    result = parse(counts(2, 1) + established + idle + statistics.delete_suffix(statistics.lines.last) + header)
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :missing_prefix_statistics, expected: 2, observed: 1))
  end

  it "requires a documented state spelling in the prefix table before normalization" do
    result = parse(counts(2, 1) + established + idle.sub("Idle", "Idle (Admin)") + statistics.sub("Idle", "Idle_(Admin)"))
    expect(result.status).to eq(:partial)
    expect(result.records.last).not_to have_key(:prefixes_by_type)
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
      expect(result.records.first).to include(peer_address: "2001:db8::1", prefixes_by_type: { type2: 2, type3: 1, type4: 0, type5: 2 })
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
