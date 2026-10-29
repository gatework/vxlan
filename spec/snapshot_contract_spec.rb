# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Vxlan::Snapshot do
  let(:observation) { Vxlan::Observation.new(name: :port_channels, status: :complete) }
  let(:attributes) do
    { target: { host: "192.0.2.1" }, fabric_key: "lab", observations: { port_channels: observation }, observed_at: Time.now.utc }
  end

  it "rejects unknown dimensions at construction rather than during lookup" do
    unknown = Vxlan::Observation.new(name: :typo, status: :complete)
    expect { described_class.new(**attributes, observations: { typo: unknown }) }.to raise_error(ArgumentError)
  end

  it "rejects invalid timestamps and connection secrets before publication" do
    expect { described_class.new(**attributes, observed_at: "invalid") }.to raise_error(ArgumentError)
    expect { described_class.new(**attributes, target: { host: "192.0.2.1", password: "secret" }) }.to raise_error(ArgumentError)
  end
end
