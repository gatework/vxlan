# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe "NX-OS runtime evidence validation" do
  def cdp(declarations)
    Vxlan::RuntimeParser.new(platform: :cisco_nxos).parse(:cdp_neighbors, "Device ID: LAB\n#{declarations}\n" \
      "Interface: Ethernet1/1, Port ID (outgoing port): Ethernet1/2\nTotal entries displayed: 1\n", complete: true)
  end

  it "excludes a CDP neighbor with conflicting names even when the first name is repeated" do
    [ %w[FIRST SECOND FIRST], %w[SECOND FIRST SECOND] ].each do |names|
      result = cdp(names.map { |name| "System Name: #{name}" }.join("\n"))
      expect(result.status).to eq(:partial)
      expect(result.records).to be_empty
    end
  end

  it "keeps conflicting CDP attributes excluded after a third declaration" do
    [ [ "Local Interface MAC", "00:11:22:33:44:55", "00:11:22:33:44:66", :local_interface_mac ],
      [ "MTU", "1500", "9000", :mtu ], [ "DC_UUID", "FIRST", "SECOND", :dc_uuid ] ].each do |label, first, second, key|
      result = cdp([ first, second, first ].map { |value| "#{label}: #{value}" }.join("\n"))
      expect(result.status).to eq(:partial), label
      expect(result.records.first.fetch(:attributes)[key]).to be_nil, label
    end
  end

  it "does not select conflicting CDP platforms or capabilities" do
    result = cdp("Platform: FIRST, Capabilities: Router\nPlatform: SECOND, Capabilities: Switch\nPlatform: FIRST, Capabilities: Router")
    expect(result.status).to eq(:partial)
    expect(result.records.first.values_at(:platform, :capabilities)).to eq([ nil, nil ])
  end

  it "accepts repeated equal CDP fields" do
    result = cdp("System Name: LAB\nSystem Name: LAB\nMTU: 1500\nMTU: 1500\nDC_UUID:\nDC_UUID:")
    expect(result).to be_complete
    expect(result.records.first).to include(remote_name: "LAB", attributes: { mtu: "1500", dc_uuid: nil })
  end

  it "excludes conflicting CDP interfaces without dropping independent neighbors or poisoning a later parse" do
    parser = Vxlan::RuntimeParser.new(platform: :cisco_nxos)
    valid = "Device ID: NEXT\nInterface: Ethernet1/3, Port ID (outgoing port): Ethernet1/4\n"
    conflict = "Device ID: LAB\nInterface: Ethernet1/1, Port ID (outgoing port): Ethernet1/2\n" \
      "Interface: Ethernet1/9, Port ID (outgoing port): Ethernet1/2\n" \
      "Interface: Ethernet1/1, Port ID (outgoing port): Ethernet1/2\n"
    result = parser.parse(:cdp_neighbors, conflict + valid + "Total entries displayed: 2\n", complete: true)
    expect(result.status).to eq(:partial)
    expect(result.records.map { |row| row[:remote_name] }).to eq([ "NEXT" ])
    expect(parser.parse(:cdp_neighbors, valid + "Total entries displayed: 1\n", complete: true)).to be_complete
  end

  def nve(group)
    Vxlan::RuntimeParser.new(platform: :cisco_nxos).parse(:nve_vnis, "Interface VNI Multicast-group State Mode Type [BD/VRF] Flags\n" \
      "nve1 10110 #{group} Up CP L2 [110] SA\n", complete: true)
  end

  it "rejects malformed, unicast and unknown NVE multicast group values" do
    %w[999.999.999.999 192.0.2.1 224.0.0.1/24 unknown].each do |group|
      result = nve(group)
      expect(result.status).to eq(:partial), group
      expect(result.records).to be_empty, group
    end
  end

  it "preserves known NVE replication markers and valid IPv4 multicast groups" do
    %w[UnicastBGP UnicastStatic n/a 239.1.1.1].each do |group|
      result = nve(group)
      expect(result).to be_complete
      expect(result.records.first[:multicast_group]).to eq(group)
    end
  end
end
