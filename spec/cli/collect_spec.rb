# frozen_string_literal: true

require_relative "../spec_helper"
require "vxlan/cli/collect"
require "tmpdir"
require "stringio"

RSpec.describe Vxlan::CLI::Collect do
  # 合成回执保留独立命令和严格首尾边界，不涉及设备或私有凭据。
  class FixtureSession
    attr_reader :commands

    def initialize
      @commands = []
    end

    def connected? = true

    def send_commands(commands)
      @commands.concat(commands)
      command = commands.fetch(0)
      body = command == "show running-config" ? "hostname LEAF\nend\n" : ""
      Struct.new(:output, :steps, :body) do
        def success? = true
        def value! = body
      end.new("#{command}\n#{body}LEAF#", [ Object.new ], body)
    end
  end

  around do |example|
    Dir.mktmpdir do |directory|
      @directory = directory
      @config = File.join(directory, "vxlan.yml")
      @envfile = File.join(directory, ".env")
      @env = { "NC_DEVICE_USERNAME" => "fixture-user" }
      @out, @error = StringIO.new, StringIO.new
      example.run
    end
  end

  # 写入仅含合成设备的临时配置，不修改项目现场文件。
  def config(**overrides)
    values = { "fabric" => "LAB", "parallel" => 2, "directory" => File.join(@directory, "reports"),
      "devices" => [ { "host" => "192.0.2.10", "name" => "LEAF-01" }, { "host" => "192.0.2.11", "name" => "LEAF-SPARE" } ],
      "dimensions" => %w[vpc configuration] }.merge(overrides.transform_keys(&:to_s))
    File.write(@config, YAML.dump(values))
  end

  # 注入串行执行器可验证逐设备业务；真实线程池在独立测试中覆盖。
  def runner(factory: nil, executor: ->(items, _parallel, &operation) { items.map(&operation) })
    described_class.new(env: @env, out: @out, error: @error, input: StringIO.new,
      connector_factory: factory, executor: executor)
  end

  def run_example(instance, *args)
    instance.run([ "--config", @config, "--env-file", @envfile, *args ])
  end

  it "uses YAML over environment defaults and CLI over YAML, without leaking secrets into public config" do
    config
    @env.merge!("VXLAN_PARALLEL" => "invalid", "NC_DEVICE_PASSWORD" => "private-fixture")
    expect(run_example(runner, "--show-config", "-p", "7")).to eq(0)
    values = JSON.parse(@out.string)
    expect(values.fetch("parallel")).to eq(7)
    expect(@out.string).not_to include("private-fixture")
  end

  it "previews filtered inventory without device credentials or a connector factory" do
    config
    @env.clear
    expect(run_example(runner, "--inventory-only", "--hosts", "192.0.2.0/24", "--exclude-name", "spare", "--json")).to eq(0)
    expect(JSON.parse(@out.string).map { |d| d.fetch("host") }).to eq([ "192.0.2.10" ])
    expect(Dir.exist?(File.join(@directory, "reports"))).to be(false)
  end

  it "rejects duplicate normalized hosts and sensitive YAML settings before connecting" do
    config(devices: [ { "host" => "2001:db8::1" }, { "host" => "2001:db8:0:0::1" } ])
    factory = double("factory")
    expect(factory).not_to receive(:call)
    expect(run_example(runner(factory: factory))).to eq(2)
    config(ssh: { "password" => "private-fixture" })
    expect(run_example(runner(factory: factory))).to eq(2)
    expect(@error.string).not_to include("private-fixture")
  end

  it "fails before connections and report creation when credentials are missing" do
    config
    @env.clear
    factory = double("factory")
    expect(factory).not_to receive(:call)
    expect(run_example(runner(factory: factory))).to eq(2)
    expect(@error.string).to include("NC_DEVICE_USERNAME")
    expect(Dir.exist?(File.join(@directory, "reports"))).to be(false)
  end

  it "loads .env without replacing process credentials, including quoted password punctuation" do
    config
    File.write(@envfile, "NC_DEVICE_USERNAME=other\nNC_DEVICE_PASSWORD='fixture#with$dollar'\n")
    expect(run_example(runner, "--show-config")).to eq(0)
    expect(@env.fetch("NC_DEVICE_USERNAME")).to eq("fixture-user")
    expect(@env.fetch("NC_DEVICE_PASSWORD")).to eq('fixture#with$dollar')
    expect(@out.string).not_to include("fixture#with")
  end

  it "retains one failed device, a complete sibling, metadata-only stdout and per-device evidence" do
    config
    session = FixtureSession.new
    factory = lambda do |device, _settings|
      connector = double("connector", platform: :cisco_nxos)
      if device.fetch("host").end_with?("11")
        allow(connector).to receive(:open).and_raise(IOError, "private diagnostic")
      else
        allow(connector).to receive(:open).and_yield(session)
      end
      connector
    end
    expect(run_example(runner(factory: factory), "--json")).to eq(1)
    summary = JSON.parse(@out.string)
    expect(summary.fetch("counts")).to eq("complete" => 1, "failed" => 1)
    expect(summary.fetch("total")).to eq(2)
    expect(session.commands).to eq([ "terminal length 0", "terminal width 511", "show running-config" ])
    expect(@out.string + @error.string).not_to include("private diagnostic", "hostname LEAF")
    directory = summary.fetch("directory")
    expect(Dir["#{directory}/devices/*.json"].size).to eq(2)
    report = JSON.parse(File.read("#{directory}/devices/LEAF-01-192.0.2.10.json"))
    expect(report.dig("snapshot", "dimensions", "configuration", "records", 0, "hostname")).to eq("LEAF")
    expect(File.stat("#{directory}/summary.json").mode & 0o777).to eq(0o600)
    expect(File.stat(directory).mode & 0o777).to eq(0o700)
  end

  it "preserves host identity in filenames even for long equal device name prefixes" do
    config(devices: [ { "host" => "192.0.2.10", "name" => "L" * 250 }, { "host" => "192.0.2.11", "name" => "L" * 250 } ])
    factory = lambda do |_device, _settings|
      connector = double("connector", platform: :cisco_nxos)
      allow(connector).to receive(:open).and_yield(FixtureSession.new)
      connector
    end
    expect(run_example(runner(factory: factory))).to eq(0)
    expect(Dir["#{@directory}/reports/*/devices/*.json"].size).to eq(2)
  end

  it "reports no devices instead of creating a successful empty batch" do
    config(devices: [])
    expect(run_example(runner, "--json")).to eq(1)
    expect(JSON.parse(@out.string)).to include("status" => "no_devices", "total" => 0)
  end
  it "resolves a config selected by .env before testing for missing files" do
    config
    File.write(@envfile, "VXLAN_CONFIG=#{@config}\n")
    instance = runner
    expect(instance.run([ "--env-file", @envfile, "--inventory-only", "--json" ])).to eq(0)
    expect(JSON.parse(@out.string).size).to eq(2)
  end

  it "initializes the config selected by .env using public defaults and CLI overrides" do
    selected = File.join(@directory, "selected.yml")
    File.write(@envfile, "VXLAN_CONFIG=#{selected}\nVXLAN_PARALLEL=9\nVXLAN_FABRIC=ENV-LAB\nNC_DEVICE_PASSWORD=private-init-secret\n")
    expect(runner.run([ "--env-file", @envfile, "--init", "--fabric", "CLI-LAB" ])).to eq(0)
    expect(File).to exist(selected)
    expect(YAML.safe_load_file(selected)).to include("parallel" => 9, "fabric" => "CLI-LAB")
    expect(File.read(selected)).not_to include("private-init-secret")
  end

  it "saves completed and pending targets when the scheduler fails unexpectedly" do
    config
    factory = lambda do |_device, _settings|
      connector = double("connector", platform: :cisco_nxos)
      allow(connector).to receive(:open).and_yield(FixtureSession.new)
      connector
    end
    executor = ->(items, _parallel, &operation) { operation.call(items.first); raise "private-scheduler-detail" }
    expect(run_example(runner(factory: factory, executor: executor), "--json")).to eq(2)
    summary = JSON.parse(@out.string)
    expect(summary).to include("status" => "incomplete", "total" => 2, "completed" => 1, "execution_error" => "RuntimeError")
    expect(summary.fetch("pending").map { |device| device.fetch("host") }).to eq([ "192.0.2.11" ])
    expect(JSON.parse(File.read(File.join(summary.fetch("directory"), "summary.json")))).to eq(summary)
    expect(@out.string + @error.string).not_to include("private-scheduler-detail")
  end

  [ RuntimeError, ArgumentError, LoadError ].each do |failure_class|
    it "retains execution failure after all devices finish without exposing #{failure_class} details" do
      config
      factory = lambda do |_device, _settings|
        connector = double("connector", platform: :cisco_nxos)
        allow(connector).to receive(:open).and_yield(FixtureSession.new)
        connector
      end
      executor = lambda do |items, _parallel, &operation|
        items.map(&operation)
        raise failure_class, "private-execution-detail"
      end
      expect(run_example(runner(factory: factory, executor: executor), "--json")).to eq(2)
      summary = JSON.parse(@out.string)
      expect(summary).to include("status" => "incomplete", "completed" => 2, "pending" => [], "execution_error" => failure_class.name)
      expect(summary.fetch("devices")).to all(include("report_saved" => true))
      expect(@out.string + @error.string).not_to include("private-execution-detail")
    end
  end

  it "saves completed evidence and marks pending targets when execution is interrupted" do
    config
    factory = lambda do |_device, _settings|
      connector = double("connector", platform: :cisco_nxos)
      allow(connector).to receive(:open).and_yield(FixtureSession.new)
      connector
    end
    executor = ->(items, _parallel, &operation) { operation.call(items.first); raise Interrupt }
    expect(run_example(runner(factory: factory, executor: executor), "--json")).to eq(130)
    summary = JSON.parse(@out.string)
    expect(summary).to include("status" => "interrupted", "total" => 2, "completed" => 1)
    expect(summary.fetch("pending").map { |device| device.fetch("host") }).to eq([ "192.0.2.11" ])
  end
  it "uses optional Netdisco inventory and keeps non-NX-OS devices out of the collection" do
    require "net/connector/netdisco"
    source = File.join(@directory, "netdisco.yml")
    File.write(source, YAML.dump("netdisco" => { "url" => "https://netdisco.example" }))
    config(devices: [], netdisco_config: source)
    nxos = double("NX-OS", ready?: true, vendor: :cisco_nxos, host: "192.0.2.10", name: "LEAF-01", model: nil)
    other = double("Other", ready?: true, vendor: :h3c)
    fleet = double("Fleet", devices: [ nxos, other ])
    allow(Net::Connector::Netdisco::Fleet).to receive(:new).with(settings: an_instance_of(Net::Connector::Netdisco::Settings)).and_return(fleet)
    @env.clear
    expect(run_example(runner, "--inventory-only", "--json")).to eq(0)
    expect(JSON.parse(@out.string).map { |device| device.fetch("host") }).to eq([ "192.0.2.10" ])
  end

  it "reports inventory failures without retaining private error messages" do
    require "net/connector/netdisco"
    source = File.join(@directory, "netdisco.yml")
    File.write(source, YAML.dump("netdisco" => { "url" => "https://netdisco.example" }))
    config(devices: [], netdisco_config: source)
    allow(Net::Connector::Netdisco::Fleet).to receive(:new).and_raise(Net::Connector::Netdisco::Inventory::Error, "private-inventory-error")
    expect(run_example(runner, "--inventory-only")).to eq(2)
    expect(@error.string).to include("VXLAN 清单或执行失败")
    expect(@error.string).not_to include("private-inventory-error")
  end

  it "aborts with a report error instead of claiming a successful batch when persistence fails" do
    config
    factory = lambda do |_device, _settings|
      connector = double("connector", platform: :cisco_nxos)
      allow(connector).to receive(:open).and_yield(FixtureSession.new)
      connector
    end
    allow_any_instance_of(Vxlan::CLI::Report).to receive(:write).and_raise(Errno::ENOSPC)
    expect(run_example(runner(factory: factory))).to eq(2)
    expect(@error.string).to include("Errno::ENOSPC")
    expect(@out.string).to include("结果 incomplete")
  end
  it "runs independent devices through the real bounded pool while each session remains sequential" do
    config
    lock = Mutex.new
    active = 0
    maximum = 0
    owner = Class.new do
      # 合成生命周期连接器只让真实线程池调度，不打开任何网络会话。
      def initialize(&operation) = @operation = operation
      def platform = :cisco_nxos
      def open(&operation) = @operation.call(&operation)
    end
    factory = lambda do |_device, _settings|
      owner.new do |&operation|
        begin
          lock.synchronize { active += 1; maximum = [ maximum, active ].max }
          sleep 0.03
          operation.call(FixtureSession.new)
        ensure
          lock.synchronize { active -= 1 }
        end
      end
    end
    expect(run_example(runner(factory: factory, executor: nil), "--json")).to eq(0)
    expect(maximum).to eq(2)
    expect(active).to eq(0)
    expect(JSON.parse(@out.string).fetch("counts")).to eq("complete" => 2)
  end

  it "retains acquired targets in an incomplete summary when device persistence fails" do
    config
    factory = lambda do |_device, _settings|
      connector = double("connector", platform: :cisco_nxos)
      allow(connector).to receive(:open).and_yield(FixtureSession.new)
      connector
    end
    allow_any_instance_of(Vxlan::CLI::Report).to receive(:write).and_raise(Errno::ENOSPC, "private-write-detail")
    expect(run_example(runner(factory: factory), "--json")).to eq(2)
    summary = JSON.parse(@out.string)
    expect(summary).to include("status" => "incomplete", "completed" => 1)
    expect(summary.fetch("pending").map { |device| device.fetch("host") }).to eq([ "192.0.2.11" ])
    expect(summary.fetch("devices").first).to include("status" => "complete", "report_saved" => false)
    expect(@out.string + @error.string).not_to include("private-write-detail")
  end

  it "preserves cancellation when the final summary also fails to persist" do
    config
    factory = double("factory")
    executor = ->(*) { raise Interrupt }
    allow_any_instance_of(Vxlan::CLI::Report).to receive(:finish).and_raise(IOError, "private-summary-detail")
    expect(run_example(runner(factory: factory, executor: executor), "--json")).to eq(130)
    expect(@error.string).to include("取消", "报告")
    expect(@out.string + @error.string).not_to include("private-summary-detail")
  end

  it "rejects an unsafe report root before invoking the connector" do
    config
    Dir.mkdir(File.join(@directory, "reports"), 0o755)
    factory = double("factory")
    expect(factory).not_to receive(:call)
    expect(run_example(runner(factory: factory))).to eq(2)
    expect(@error.string).to include("0700")
  end
end
