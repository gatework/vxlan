# frozen_string_literal: true

require_relative "../spec_helper"
require "vxlan/cli"
require "vxlan/cli/collect"
require "net/connector"
require "rbconfig"

RSpec.describe Vxlan::CLI::Connector do
  # 只运行本地 PTY 子进程，完整经过已安装连接器的登录、命令回显与关闭逻辑。
  class FixtureTransport < Net::Connector::Transports::Pty
    def argv
      program = <<~'PROGRAM'
        $stdout.sync = true
        print "LEAF#"
        while (line = gets)
          print line
          print "hostname LEAF\r\nend\r\n" if line.strip == "show running-config"
          print "LEAF#"
        end
      PROGRAM
      [ RbConfig.ruby, "-e", program ]
    end
  end

  it "uses valid native SSH configuration and releases its owned PTY session" do
    values = { host_key_policy: "strict", command_timeout: 2, login_timeout: 2, username: "fixture-user" }
    configuration = Net::Connector::Configuration.new(host: "192.0.2.10", **values)
    configuration.validate_endpoint!
    transport = FixtureTransport.new(configuration)
    connector = described_class.new({ "host" => "192.0.2.10" }, values.merge(transport: transport))
    native = nil
    original = Net::Connector.method(:open)
    allow(Net::Connector).to receive(:open) do |vendor, **settings, &operation|
      original.call(vendor, **settings) do |device|
        native = device
        allow(device).to receive(:with_operation).and_call_original
        operation.call(device)
      end
    end
    snapshot = Vxlan::Collector.new.collect(connector: connector, target: { host: "192.0.2.10" }, fabric_key: "LAB", dimensions: %i[vpc configuration])
    expect(snapshot).to be_complete
    expect(snapshot.observations.fetch(:configuration).records.first[:hostname]).to eq("LEAF")
    expect(snapshot.observations.fetch(:vpc).issues).to eq([ { code: :vpc_not_configured } ])
    expect(native).not_to be_connected
    expect(native).to have_received(:with_operation).with(:vxlan).once
  end

  it "yields the native device while preventing another owner from entering the collection lease" do
    values = { host_key_policy: "strict", command_timeout: 2, login_timeout: 2, username: "fixture-user" }
    transport = FixtureTransport.new(Net::Connector::Configuration.new(host: "192.0.2.10", **values))
    connector = described_class.new({ "host" => "192.0.2.10" }, values.merge(transport: transport))
    connector.open do |native|
      expect(native).to be_a(Net::Connector::Base)
      failure = Thread.new do
        native.with_operation(:competing) { :unexpected }
      rescue Net::Connector::SessionBusy => error
        error
      end.value
      expect(failure).to be_a(Net::Connector::SessionBusy)
      snapshot = Vxlan::Collector.new.collect_session(session: native, target: {}, fabric_key: "LAB", dimensions: [ :configuration ])
      expect(snapshot).to be_complete
      expect(native).to be_connected
    end
  end

  [ :close, :with_operation ].each do |finalizer|
    it "retains completed facts when native #{finalizer} finalization fails" do
      values = { host_key_policy: "strict", command_timeout: 2, login_timeout: 2, username: "fixture-user" }
      transport = FixtureTransport.new(Net::Connector::Configuration.new(host: "192.0.2.10", **values))
      connector = described_class.new({ "host" => "192.0.2.10" }, values.merge(transport: transport))
      native = nil
      allow(Net::Connector).to receive(:open).and_wrap_original do |original, vendor, **settings, &operation|
        original.call(vendor, **settings) do |device|
          native = device
          allow(device).to receive(finalizer).and_wrap_original do |method, *args, &block|
            method.call(*args, &block)
            raise IOError, "private-finalization-detail"
          end
          operation.call(device)
        end
      end
      snapshot = Vxlan::Collector.new.collect(connector: connector, target: {}, fabric_key: "LAB", dimensions: [ :configuration ])
      expect(snapshot.observations.fetch(:configuration)).to be_complete
      expect(snapshot.observations.fetch(:collection).issues).to eq([ { code: :session_close_failed } ])
      expect(native).not_to be_connected
      expect(snapshot.inspect).not_to include("private-finalization-detail", "hostname LEAF")
    end
  end
  it "collects and saves evidence through the formal CLI using a local PTY" do
    require "tmpdir"
    require "stringio"
    Dir.mktmpdir do |directory|
      config = File.join(directory, "vxlan.yml")
      File.write(config, YAML.dump("devices" => [ { "host" => "192.0.2.10" } ], "dimensions" => [ "configuration" ], "directory" => "reports"))
      factory = lambda do |device, settings|
        transport = FixtureTransport.new(Net::Connector::Configuration.new(host: device.fetch("host"), **settings))
        described_class.new(device, settings.merge(transport: transport))
      end
      out, error = StringIO.new, StringIO.new
      status = Vxlan::CLI.run([ "collect", "--config", config, "--json" ],
        discovery: { directories: [] }, env: { "NC_DEVICE_USERNAME" => "fixture-user" }, out: out, error: error, input: StringIO.new, connector_factory: factory)
      expect(status).to eq(0), error.string
      summary = JSON.parse(out.string)
      expect(summary.fetch("counts")).to eq("complete" => 1)
      report = Dir[File.join(directory, "reports/*/evidence/*.json")].fetch(0)
      expect(JSON.parse(File.read(report)).dig("snapshot", "dimensions", "configuration", "records", 0, "hostname")).to eq("LEAF")
    end
  end
end
