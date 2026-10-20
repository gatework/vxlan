# frozen_string_literal: true

require_relative "../spec_helper"
require "vxlan/fabric/scope"

RSpec.describe Vxlan::Fabric::Scope do
  it "rejects addresses assigned to more than one role or Fabric" do
    [ { "A" => { "leaves" => [ "192.0.2.1" ], "borders" => [ "192.0.2.1" ] } },
      { "A" => { "leaves" => %w[192.0.2.1 192.0.2.2] }, "B" => { "leaves" => %w[192.0.2.2 192.0.2.3] } } ].each do |groups|
      expect { described_class.new("fabrics" => groups) }.to raise_error(ArgumentError)
    end
  end

  it "separates unassigned collected devices from assigned devices missing evidence" do
    scope = described_class.new("fabrics" => { "A" => { "leaves" => %w[192.0.2.1 192.0.2.2] } })
    expect(scope.coverage(%w[192.0.2.1 192.0.2.3])).to include(assigned: [ "192.0.2.1" ], missing: [ "192.0.2.2" ], unassigned: [ "192.0.2.3" ])
  end

  it "preserves validated membership independently of caller and returned string mutations" do
    hosts = [ +"192.0.2.1", +"192.0.2.2" ]
    scope = described_class.new("fabrics" => { "A" => { "leaves" => hosts } })
    hosts.last.replace("192.0.2.1")
    hosts.clear

    expect(scope.coverage(%w[192.0.2.1 192.0.2.2])).to include(assigned: %w[192.0.2.1 192.0.2.2], missing: [])
    expect { scope.groups["A"]["leaves"].last.replace("192.0.2.1") }.to raise_error(FrozenError)
    expect { scope.hosts.first.clear }.to raise_error(FrozenError)
  end
end
