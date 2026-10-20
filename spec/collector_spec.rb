# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Vxlan::Collector do
  let(:target) { { key: "fixture:leaf", host: +"192.0.2.10" } }
  let(:connector) { double("Connector", platform: :cisco_nxos) }
  let(:session) { double("CLI session", connected?: true) }
  let(:now) { Time.utc(2026, 10, 16, 8) }
  let(:collector) { described_class.new(clock: -> { now }) }
  let(:outputs) do
    { "terminal length 0" => "", "terminal width 511" => "",
      "show running-config" => "hostname LEAF\nend\n",
      "show port-channel summary" => "Number of port-channels: 0\n" }
  end

  before do
    allow(connector).to receive(:open).and_yield(session)
    allow(session).to receive(:send_commands) do |commands|
      expect(commands.size).to eq(1)
      body = outputs.fetch(commands.first)
      raise body if body.is_a?(Exception)

      double("Command receipt", output: "#{commands.first}\n#{body}LEAF#", success?: true, steps: [ Object.new ], value!: body)
    end
  end

  # 通过公开注入接口采集，不依赖宿主应用模型。
  def collect(*dimensions)
    collector.collect(connector: connector, target: target, fabric_key: "LAB", dimensions: dimensions)
  end

  it "uses one injected connection and retains caller identity without retaining raw output" do
    expect(connector).to receive(:open).once.and_yield(session)
    result = collect(:configuration)
    target[:host].replace("192.0.2.20")

    expect(result).to be_complete
    expect(result.target).to eq(key: "fixture:leaf", host: +"192.0.2.10")
    observation = result.dimensions.fetch(:configuration)
    expect(observation.records.first[:hostname]).to eq("LEAF")
    expect(observation.evidence.first).to include(command: "show running-config", sha256: a_string_matching(/\A[0-9a-f]{64}\z/))
    expect(observation.evidence.inspect).not_to include("hostname LEAF")
  end

  it "keeps a command failure local while continuing later independent queries" do
    outputs["show port-channel summary"] = IOError.new("private transport detail")
    result = collect(:port_channels, :configuration)

    expect(result.dimensions.fetch(:port_channels).status).to eq(:failed)
    expect(result.dimensions.fetch(:configuration)).to be_complete
    expect(result.dimensions.fetch(:collection).status).to eq(:partial)
    expect(result.dimensions.fetch(:port_channels).issues.inspect).not_to include("private transport detail")
  end

  it "owns identity and dimension selection before invoking connection callbacks" do
    dimensions = %i[configuration port_channels]
    fabric_key = +"LAB"
    allow(connector).to receive(:open) do |&operation|
      target[:host].replace("198.51.100.99")
      fabric_key.replace("CHANGED")
      dimensions.replace([ :configuration ])
      operation.call(session)
    end

    result = collector.collect(connector: connector, target: target, fabric_key: fabric_key, dimensions: dimensions)
    expect(result).to be_complete
    expect(result.target[:host]).to eq("192.0.2.10")
    expect(result.fabric_key).to eq("LAB")
    expect(result.dimensions.keys).to contain_exactly(:configuration, :port_channels, :collection)
    expect(session).to have_received(:send_commands).with([ "show port-channel summary" ])
    expect(target[:host]).to eq("198.51.100.99")
  end

  it "uses complete configuration to distinguish unused vPC and port channels from failed parsing" do
    outputs["show port-channel summary"] = ""
    expect(session).not_to receive(:send_commands).with([ "show vpc brief" ])
    result = collect(:configuration, :vpc, :port_channels)

    expect(result).to be_complete
    expect(result.dimensions.fetch(:vpc).issues).to eq([ { code: :vpc_not_configured } ])
    expect(result.dimensions.fetch(:port_channels).issues).to eq([ { code: :port_channels_not_configured } ])
  end

  it "retains acquired facts when closing the injected session fails" do
    allow(connector).to receive(:open) do |&operation|
      operation.call(session)
      raise IOError, "private close diagnostic"
    end
    result = collect(:configuration)

    expect(result.dimensions.fetch(:configuration)).to be_complete
    expect(result.dimensions.fetch(:collection).issues).to eq([ { code: :session_close_failed } ])
  end

  it "retains the first observations without replaying when a connector yields again" do
    allow(connector).to receive(:open) do |&operation|
      operation.call(session)
      outputs["show running-config"] = "hostname OTHER\nend\n"
      operation.call(session)
    end
    result = collect(:configuration)
    expect(session).to have_received(:send_commands).with([ "show running-config" ]).once
    expect(result.dimensions.fetch(:configuration).records.first[:hostname]).to eq("LEAF")
    expect(result.dimensions.fetch(:collection).issues).to eq([ { code: :session_reentered } ])
    expect(result).not_to be_complete
  end

  it "rejects invalid targets and selections before opening a connection" do
    expect(connector).not_to receive(:open)
    expect { collector.collect(connector: connector, target: "device", fabric_key: "LAB") }.to raise_error(ArgumentError)
    [ [], [ :configuration, :configuration ], [ :unknown ] ].each do |dimensions|
      expect { collect(*dimensions) }.to raise_error(ArgumentError)
    end
  end

  it "classifies an unopened connection without inventing observations" do
    allow(connector).to receive(:open).and_raise(IOError, "private login detail")
    expect(session).not_to receive(:send_commands)
    result = collect(:configuration, :nve_peers)
    expect(result.dimensions.values.map(&:status)).to eq([ :failed, :failed, :failed ])
    expect(result.dimensions.fetch(:collection).issues).to eq([ { code: :connection_failed } ])
  end

  it "never marks an unyielded session as complete or omits requested dimensions" do
    allow(connector).to receive(:open).and_return(nil)
    result = collect(:configuration, :nve_peers)
    expect(result).not_to be_complete
    expect(result.dimensions.keys).to eq(%i[configuration nve_peers collection])
    expect(result.dimensions.values.map(&:status)).to eq([ :failed, :failed, :failed ])
    expect(result.dimensions.fetch(:collection).issues).to eq([ { code: :session_not_opened } ])
  end

  it "does not replay a query or submit remaining dimensions after disconnect" do
    allow(session).to receive(:send_commands) do |commands|
      if commands == [ "show running-config" ]
        allow(session).to receive(:connected?).and_return(false)
        raise IOError, "private disconnect detail"
      end
      double("preparation", output: "LEAF#", success?: true, steps: [ Object.new ], value!: "")
    end
    result = collect(:configuration, :nve_peers)
    expect(session).to have_received(:send_commands).with([ "show running-config" ]).once
    expect(session).not_to have_received(:send_commands).with([ "show nve peers" ])
    expect(result.dimensions.fetch(:nve_peers).issues.first).to include(skipped: true)
    expect(result).not_to be_complete
  end

  it "rejects an incompatible platform before submitting a command" do
    allow(connector).to receive(:platform).and_return(:cisco_ios)
    expect(connector).not_to receive(:open)

    expect { collect(:configuration) }.to raise_error(ArgumentError, "VXLAN requires Cisco NX-OS")
  end
  it "collects a borrowed session without opening or closing it" do
    expect(session).not_to receive(:open)
    expect(session).not_to receive(:close)
    result = collector.collect_session(session: session, target: target, fabric_key: "LAB", dimensions: [ :configuration ])
    expect(result).to be_complete
    expect(result.dimensions.fetch(:configuration).records.first[:hostname]).to eq("LEAF")
  end

  it "collects configuration first when dependent dimensions were requested in another order" do
    outputs["show port-channel summary"] = ""
    expect(session).not_to receive(:send_commands).with([ "show vpc brief" ])
    result = collector.collect_session(session: session, target: target, fabric_key: "LAB", dimensions: %i[vpc port_channels configuration])
    expect(result).to be_complete
    expect(result.dimensions.keys).to eq(%i[vpc port_channels configuration collection])
  end

  it "validates borrowed requests before sending any commands" do
    expect(session).not_to receive(:send_commands)
    expect { collector.collect_session(session: session, target: target, fabric_key: "LAB", platform: :h3c) }.to raise_error(ArgumentError)
    expect { collector.collect_session(session: session, target: target, fabric_key: "LAB", dimensions: []) }.to raise_error(ArgumentError)
  end
end
