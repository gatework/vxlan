# frozen_string_literal: true

require_relative "../spec_helper"
require "vxlan/service/catalog"

RSpec.describe Vxlan::Service::Catalog do
  it "retains L2 evidence when an NVE member incorrectly claims the VNI is L3" do
    config = { "vlan_vnis" => { "8" => 10008 }, "nve" => { "members" => { "10008" => { "associate_vrf" => true } } }, "evpn" => { "10008" => { "type" => "l2" } } }
    row = described_class.new("192.0.2.1" => config).services.fetch(10008).first
    expect(row[:missing]).to include("NVE L2")
  end

  it "marks the EVPN layer conflict as incomplete instead of trusting block presence" do
    config = { "vlan_vnis" => { "8" => 10008 }, "nve" => { "members" => { "10008" => { "associate_vrf" => false } } }, "evpn" => { "10008" => { "type" => "l3" } } }
    expect(described_class.new("192.0.2.1" => config).services.fetch(10008).first[:missing]).to include("EVPN L2")
  end

  it "recognizes equivalent explicit and auto route targets with a two-byte ASN" do
    auto = described_class.route_targets([ { "direction" => "both", "target" => "auto" } ], asn: 65001, vni: 10008)
    explicit = described_class.route_targets([ { "direction" => "both", "target" => "65001:10008" } ], asn: 65001, vni: 10008)
    expect(auto).to eq(explicit)
    expect(auto).to contain_exactly([ nil, false, "import", "65001:10008" ], [ nil, false, "export", "65001:10008" ])
  end

  it "does not infer an explicit RT equivalence for unknown or four-byte ASNs" do
    [ nil, 4_200_000_001 ].each do |asn|
      auto = described_class.route_targets([ { "direction" => "both", "target" => "auto" } ], asn: asn, vni: 10008)
      explicit = described_class.route_targets([ { "direction" => "both", "target" => "#{asn}:10008" } ], asn: asn, vni: 10008)
      expect(auto).not_to eq(explicit)
    end
  end
end
