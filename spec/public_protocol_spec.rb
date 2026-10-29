# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_runner/document"

RSpec.describe "Vxlan public observation protocol" do
  it "parses an explicit platform and command and exposes the shared snapshot contract" do
    parser = Vxlan::RuntimeParser.new(platform: :cisco_nxos)
    observations = parser.parse_many([ :port_channels ], "Number of port-channels: 0\n", complete: true, command: "show port-channel summary")
    expect(observations.fetch(:port_channels)).to be_complete
    snapshot = Vxlan::Snapshot.new(target: { host: "192.0.2.1" }, fabric_key: "LAB", observations: observations, observed_at: Time.utc(2026, 10, 29))
    expect(snapshot.observation(:port_channels)).to equal(observations.fetch(:port_channels))
    expect(snapshot.observation(:configuration).status).to eq(:not_requested)
    expect { snapshot.observation(:invalid) }.to raise_error(ArgumentError)
    document = CtxRunner::Document.call(snapshot)
    expect(document.fetch("observations").fetch("port_channels").fetch("status")).to eq("complete")
    expect(document).not_to have_key("dimensions")
  end
end
