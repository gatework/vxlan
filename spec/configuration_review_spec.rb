# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Vxlan::ConfigurationReview do
  def review(body, complete: true)
    observation = Vxlan::Configuration.new.parse("hostname LEAF\n#{body}", complete: complete)
    expect(observation.status).to eq(complete ? :complete : :partial)
    observation.records.first.fetch(:review_findings)
  end

  it "accepts VLAN-backed L3 VNIs with a forwarding SVI and a matching VRF" do
    body = <<~CONFIG
      vlan 2001
        vn-segment 50100
      vrf context BLUE
        vni 50100
      interface Vlan2001
        vrf member BLUE
        ip forward
      interface nve1
        member vni 50100 associate-vrf
    CONFIG

    expect(review(body)).to be_empty
  end

  it "reports L3 NVE members without a configured VRF using that VNI" do
    expect(review("interface nve1\n  member vni 50100 associate-vrf\n")).to eq([
      { code: :nve_l3_without_vrf, vni: 50100 }
    ])
  end

  [ [ "l2", " associate-vrf" ], [ "l3", "" ] ].each do |type, association|
    it "reports an EVPN #{type} definition with the opposite NVE layer" do
      findings = review("evpn\n  vni 50100 #{type}\ninterface nve1\n  member vni 50100#{association}\n")

      expect(findings).to include(code: :vni_layer_conflict, vni: 50100, evpn_type: type)
    end
  end

  it "accepts consistent L2 and L3 associations while separating review from runtime health" do
    body = <<~CONFIG
      nv overlay evpn
      vlan 110
        vn-segment 10110
      vrf context BLUE
        vni 50100
      interface nve1
        member vni 10110
        member vni 50100 associate-vrf
      evpn
        vni 10110 l2
    CONFIG

    expect(review(body)).to be_empty
  end

  it "withholds missing-reference findings from incomplete configuration" do
    expect(review("interface nve1\n  member vni 50100 associate-vrf\n", complete: false)).to be_empty
  end
end
