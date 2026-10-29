# frozen_string_literal: true

require_relative "../spec_helper"
require "vxlan/cli/collect"
require "tmpdir"
require "stringio"
require "timeout"

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
      end.new("#{command}\n#{body}LEAF#", [ { command: command } ], body)
    end
  end

  around do |example|
    Dir.mktmpdir do |directory|
      @directory = directory
      @config = File.join(directory, "vxlan.yml")
      @envfile = File.join(directory, ".env")
      File.write(@envfile, "")
      @env = { "NC_DEVICE_USERNAME" => "fixture-user" }
      @out, @error = StringIO.new, StringIO.new
      example.run
    end
  end

  # 写入仅含合成设备的临时配置，不修改项目现场文件。
  it "shares address, name, vendor and model selection without opening sessions" do
    config(devices: [ { "host" => "192.0.2.10", "name" => "EDGE", "model" => "S6800" },
      { "host" => "192.0.2.11", "name" => "EDGE-spare", "model" => "S6800" } ])
    args = [ "--plan", "--json", "--hosts", "192.0.2.1-20", "--name", "edge", "--exclude-name", "spare",
      "--vendor", "cisco_nxos", "--model", "s68*", "--model-match", "glob" ]
    expect(run_example(runner, *args)).to eq(0)
    expect(JSON.parse(@out.string).map { |row| row.fetch("host") }).to eq([ "192.0.2.10" ])
    expect(Dir).not_to exist(File.join(@directory, "reports"))
  end


  it "rejects selected duplicate addresses across platforms but permits excluded duplicates" do
    require "net/connector/netdisco"
    config(devices: [], netdisco: { "url" => "https://netdisco.example" })
    domain = { "vendor" => "Cisco", "os" => "NX-OS" }
    inventory = Struct.new(:devices).new([
      domain.merge("ip" => "192.0.2.10", "name" => "selected"),
      { "ip" => "192.0.2.10", "vendor" => "Juniper", "os" => "JUNOS", "name" => "conflict" },
      domain.merge("ip" => "192.0.2.11", "name" => "unique"),
      { "ip" => "invalid", "vendor" => "H3C" }
    ])
    allow_any_instance_of(Net::Connector::Netdisco::Settings).to receive(:inventory).and_return(inventory)
    @env.clear
    expect(run_example(runner, "--inventory-only", "--json", "--host", "192.0.2.10")).to eq(2)
    expect(@error.string).to include("Duplicate management address")
    expect(@out.string).to be_empty
    @error.truncate(0)
    expect(run_example(runner, "--inventory-only", "--json", "--host", "192.0.2.11")).to eq(0)
    expect(JSON.parse(@out.string).map { |row| row.fetch("host") }).to eq([ "192.0.2.11" ])
    expect(@error.string).to include("duplicate_host=2", "invalid_address=1")
    expect(Dir).not_to exist(File.join(@directory, "reports"))
  end

  it "uses the displayed fallback name when selecting unnamed duplicate addresses" do
    require "net/connector/netdisco"
    config(devices: [], netdisco: { "url" => "https://netdisco.example" })
    domain = { "vendor" => "Cisco", "os" => "NX-OS" }
    source = Struct.new(:devices).new([
      domain.merge("ip" => "192.0.2.10"),
      { "ip" => "192.0.2.10", "vendor" => "Juniper", "os" => "JUNOS" },
      domain.merge("ip" => "192.0.2.11")
    ])
    allow_any_instance_of(Net::Connector::Netdisco::Settings).to receive(:inventory).and_return(source)
    expect(run_example(runner, "--plan", "--json", "--name", "192.0.2.10")).to eq(2)
    expect(@out.string).to be_empty
    expect(run_example(runner, "--plan", "--json", "--exclude-name", "192.0.2.10")).to eq(0)
    expect(JSON.parse(@out.string).map { |row| row.fetch("host") }).to eq([ "192.0.2.11" ])
  end

  def config(**overrides)
    values = { "fabric" => "LAB", "parallel" => 2, "directory" => File.join(@directory, "reports"),
      "devices" => [ { "host" => "192.0.2.10", "name" => "LEAF-01" }, { "host" => "192.0.2.11", "name" => "LEAF-SPARE" } ],
      "dimensions" => %w[vpc configuration] }.merge(overrides.transform_keys(&:to_s))
    File.write(@config, YAML.dump(values))
  end

  # 注入串行执行器可验证逐设备业务；真实线程池在独立测试中覆盖。
  def runner(factory: nil, executor: ->(items, _parallel, &operation) { items.map(&operation) })
    described_class.new(discovery: { directories: [], home: @directory, cwd: @directory }, env: @env, out: @out, error: @error, input: StringIO.new,
      connector_factory: factory, executor: executor)
  end

  def run_example(instance, *args)
    instance.run([ "--config", @config, "--env-file", @envfile, *args ])
  end

  it "rejects insufficient device resources before connecting or creating a report" do
    config
    allow(Process).to receive(:getrlimit).with(:NOFILE).and_return([ 150, 150 ])
    factory = ->(*) { raise "connection must not start" }
    expect(run_example(runner(factory: factory, executor: nil))).to eq(2)
    expect(@error.string).to include("Insufficient local file descriptor limit", "without connecting to devices")
    expect(Dir).not_to exist(File.join(@directory, "reports"))
  end

  it "reserves resources for selected devices rather than the configured maximum" do
    config(parallel: 50)
    allow(Process).to receive(:getrlimit).with(:NOFILE).and_return([ 150, 150 ])
    factory = lambda do |_device, _settings|
      connector = double("connector", platform: :cisco_nxos)
      allow(connector).to receive(:open).and_yield(FixtureSession.new)
      connector
    end
    expect(run_example(runner(factory: factory, executor: nil), "--host", "192.0.2.10", "--json")).to eq(0)
    expect(JSON.parse(@out.string)).to include("completed" => 1)
  end

  it "closes concurrent sessions before publishing an interrupted batch" do
    config
    started, blocked, closed = Queue.new, Queue.new, Queue.new
    factory = lambda do |device, _settings|
      connector = double("connector", platform: :cisco_nxos)
      allow(connector).to receive(:open) do
        begin
          if device.fetch("host").end_with?("10")
            started.pop
            raise Interrupt
          end
          started << true
          blocked.pop
        ensure
          closed << Thread.current
        end
      end
      connector
    end
    status = Timeout.timeout(2) { run_example(runner(factory: factory, executor: nil), "--quiet", "--json") }
    expect(status).to eq(130)
    expect(closed.size).to eq(2)
    expect(2.times.map { closed.pop }).to all(satisfy { |worker| !worker.alive? })
    expect(JSON.parse(@out.string)).to include("status" => "interrupted", "completed" => 0)
  end

  it "stops an active device when another device report cannot be saved" do
    config
    started, blocked, closed = Queue.new, Queue.new, Queue.new
    factory = lambda do |device, _settings|
      connector = double("connector", platform: :cisco_nxos)
      allow(connector).to receive(:open) do |&operation|
        begin
          if device.fetch("host").end_with?("10")
            started.pop
            operation.call(FixtureSession.new)
          else
            started << true
            blocked.pop
          end
        ensure
          closed << Thread.current
        end
      end
      connector
    end
    allow_any_instance_of(Vxlan::CLI::Report).to receive(:write).and_raise(Errno::ENOSPC)
    status = Timeout.timeout(2) { run_example(runner(factory: factory, executor: nil), "--quiet", "--json") }
    expect(status).to eq(2)
    expect(closed.size).to eq(2)
    expect(2.times.map { closed.pop }).to all(satisfy { |worker| !worker.alive? })
    summary = JSON.parse(@out.string)
    expect(summary).to include("status" => "incomplete", "completed" => 1, "report_error" => "Errno::ENOSPC")
    expect(summary.fetch("devices").first).to include("report_saved" => false)
  end

  it "uses backup-style batch progress and keeps ordinary successful devices quiet" do
    config
    factory = lambda do |device, _settings|
      raise IOError, "private diagnostic" if device.fetch("host").end_with?("11")
      connector = double("connector", platform: :cisco_nxos)
      allow(connector).to receive(:open).and_yield(FixtureSession.new)
      connector
    end
    expect(run_example(runner(factory: factory))).to eq(1)
    expect(@out.string).to be_empty
    expect(@error.string).to include("Inventory 2 devices; selected 2; skipped 0 devices; concurrency 2", "192.0.2.11  Incomplete", "Incomplete categories: ",
      "Batch finished: succeeded 1, partial 0, failed 1, skipped 0", "Text report: ")
    expect(@error.string).not_to include("已采集 2 台 |", "192.0.2.10  ", "private diagnostic", "hostname LEAF")
  end

  it "refreshes terminal stages while preserving a clean JSON stream and joins the observer" do
    config
    @error.define_singleton_method(:tty?) { true }
    before = Thread.list
    factory = lambda do |_device, settings|
      expect(@error.string).to include("Logging in 1")
      expect(settings.fetch(:on_event)).to respond_to(:call)
      connector = double("connector", platform: :cisco_nxos)
      allow(connector).to receive(:open).and_yield(FixtureSession.new)
      connector
    end
    expect(run_example(runner(factory: factory), "--json")).to eq(0)
    expect(JSON.parse(@out.string).fetch("counts")).to eq("complete" => 2)
    expect(@error.string).to include("2/2 100%", "\e[2K", "Batch finished: succeeded 2")
    expect(Thread.list - before).to be_empty
  end

  it "keeps quiet collection silent while preserving its report and JSON result" do
    config
    factory = ->(*) { raise IOError, "private diagnostic" }
    expect(run_example(runner(factory: factory), "--quiet", "--json")).to eq(1)
    expect(JSON.parse(@out.string).fetch("counts")).to eq("failed" => 2)
    expect(@error.string).to be_empty
  end

  [ "Configuration: ", "Batch finished: " ].each do |stage|
    it "preserves collected results and records a display failure at #{stage}" do
      config
      writer = @error.method(:write)
      @error.define_singleton_method(:write) do |text|
        raise IOError, "private terminal error" if text.include?(stage)
        writer.call(text)
      end
      calls = 0
      factory = lambda do |_device, _settings|
        calls += 1
        connector = double("connector", platform: :cisco_nxos)
        allow(connector).to receive(:open).and_yield(FixtureSession.new)
        connector
      end
      expect(run_example(runner(factory: factory), "--json")).to eq(1)
      summary = JSON.parse(@out.string)
      expect(calls).to eq(2)
      expect(summary).to include("status" => "incomplete", "counts" => { "complete" => 2 }, "output_error" => { "host" => nil, "error_type" => "IOError" })
      expect(JSON.parse(File.read(File.join(summary.fetch("directory"), "summary.json")))).to eq(summary)
      expect(@out.string + @error.string).not_to include("private terminal error")
    end
  end

  [ Interrupt, RuntimeError ].each do |failure|
    it "preserves #{failure} exit status when stderr has permanently failed" do
      config
      @error.define_singleton_method(:write) { |*| raise IOError, "private terminal error" }
      factory = lambda do |_device, _settings|
        connector = double("connector", platform: :cisco_nxos)
        allow(connector).to receive(:open).and_yield(FixtureSession.new)
        connector
      end
      executor = lambda do |devices, _parallel, &operation|
        operation.call(devices.first)
        raise failure, "private execution error"
      end
      expect(run_example(runner(factory: factory, executor: executor), "--json")).to eq(failure == Interrupt ? 130 : 2)
      summary = JSON.parse(@out.string)
      expect(summary).to include("status" => failure == Interrupt ? "interrupted" : "incomplete")
      expect(summary.fetch("output_error")).to include("error_type" => "IOError")
      expect(summary.fetch("devices").first).to include("status" => "complete", "report_saved" => true)
      expect(@out.string).not_to include("private terminal error", "private execution error")
    end
  end

  [ [ :throw, false ], [ :throw, true ], [ :interrupt, false ] ].each do |exit_kind, recovery_error|
    it "withdraws completion without replaying final progress (#{exit_kind}, recovery_error=#{recovery_error})" do
      config
      writer = @error.method(:write)
      progress_attempts = 0
      @error.define_singleton_method(:write) do |text|
        if text.include?("Batch finished:")
          progress_attempts += 1
          raise Interrupt if exit_kind == :interrupt
          throw :stop, :abandoned
        end
        writer.call(text)
      end
      if recovery_error
        original = File.method(:rename)
        allow(File).to receive(:rename) do |source, target|
          raise Errno::ENOSPC if progress_attempts.positive? && target.end_with?("/summary.txt")
          original.call(source, target)
        end
      end
      calls = 0
      factory = lambda do |_device, _settings|
        calls += 1
        connector = double("connector", platform: :cisco_nxos)
        allow(connector).to receive(:open).and_yield(FixtureSession.new)
        connector
      end
      value = catch(:stop) { run_example(runner(factory: factory), "--json") }
      expect(value).to eq(exit_kind == :throw ? :abandoned : 130)
      saved = JSON.parse(File.read(Dir[File.join(@directory, "reports/*/summary.json")].fetch(0)))
      expect(saved).to include("status" => "interrupted", "completed" => 2, "counts" => { "complete" => 2 })
      expect(saved.fetch("devices")).to all(include("status" => "complete", "report_saved" => true))
      expect(calls).to eq(2)
      expect(progress_attempts).to eq(1)
    end
  end

  it "isolates environment files between runs while preserving explicit process values" do
    config
    files = %w[first second].map { |name| File.join(@directory, "#{name}.env") }
    files.each_with_index { |path, i| File.write(path, "VXLAN_FABRIC=FABRIC#{i}\nNC_DEVICE_USERNAME=ignored\nNC_DEVICE_PASSWORD=password#{i}\n") }
    settings_seen = []
    factory = lambda do |_device, settings|
      settings_seen << settings
      connector = double("connector", platform: :cisco_nxos)
      allow(connector).to receive(:open).and_yield(FixtureSession.new)
      connector
    end
    instance = runner(factory: factory)
    files.each do |path|
      expect(instance.run([ "--config", @config, "--env-file", path ])).to eq(0), @error.string
    end
    expect(settings_seen.map { |values| values[:password] }).to eq(%w[password0 password0 password1 password1])
    expect(settings_seen.map { |values| values[:username] }.uniq).to eq([ "fixture-user" ])
    expect(@env).to eq("NC_DEVICE_USERNAME" => "fixture-user")
    expect(@out.string + @error.string).not_to include("password0", "password1")
  end

  it "uses the Fabric policy validated before collection even when its file changes mid-batch" do
    policy_path = File.join(@directory, "fabrics.yml")
    File.write(policy_path, YAML.dump("fabrics" => { "LAB" => { "leaves" => %w[192.0.2.10 192.0.2.11] } }))
    config(fabric_policy: policy_path)
    factory = lambda do |_device, _settings|
      File.write(policy_path, "invalid: replacement\n")
      connector = double("connector", platform: :cisco_nxos)
      allow(connector).to receive(:open).and_yield(FixtureSession.new)
      connector
    end
    expect(run_example(runner(factory: factory), "--json")).to eq(0), @error.string
    plan = JSON.parse(File.read(Dir[File.join(@directory, "reports/*/plan.json")].fetch(0)))
    expect(plan.dig("fabric", "inventory", "groups", "LAB", "leaves")).to eq(%w[192.0.2.10 192.0.2.11])
    expect(plan.dig("fabric", "inventory", "unassigned")).to be_empty
  end

  [ false, true ].each do |interrupted|
    it "keeps acquired facts and exit priority when summary text publication fails (interrupted=#{interrupted})" do
      config
      calls = 0
      factory = lambda do |_device, _settings|
        calls += 1
      connector = double("connector", platform: :cisco_nxos)
      allow(connector).to receive(:open).and_yield(FixtureSession.new)
      connector
      end
      executor = lambda do |items, _parallel, &operation|
        if interrupted
          operation.call(items.first)
          raise Interrupt
        end
        items.map(&operation)
      end
      original = File.method(:rename)
      allow(File).to receive(:rename) do |source, target|
        raise Errno::ENOSPC, "private-publication-detail" if target.end_with?("/summary.txt")
        original.call(source, target)
      end
      expect(run_example(runner(factory: factory, executor: executor), "--json")).to eq(interrupted ? 130 : 2)
      saved_path = Dir[File.join(@directory, "reports/*/summary.json")].fetch(0)
      saved = JSON.parse(File.read(saved_path))
      expect(saved.fetch("status")).to eq(interrupted ? "interrupted" : "incomplete")
      expect(saved.fetch("devices")).to all(include("status" => "complete", "report_saved" => true))
      expect(calls).to eq(saved.fetch("completed"))
      expect(@out.string).to eq("")
      expect(@error.string).not_to include("private-publication-detail")
    end
  end

  it "rejects false filter lists before exposing config or creating reports" do
    config(names: false)
    instance = described_class.new(discovery: { directories: [], home: @directory, cwd: @directory }, env: @env, out: @out, error: @error, input: StringIO.new)
    expect(instance.run([ "--config", @config, "--env-file", @envfile, "--show-config" ])).to eq(2)
    expect(@out.string).to eq("")
    expect(Dir).not_to exist(File.join(@directory, "reports"))
  end

  it "keeps independent batches when a runner is reused and preserves old reports after invalid input" do
    config
    factory = ->(*) { raise IOError, "fixture connection failure" }
    executor = ->(items, _parallel, &operation) { items.map(&operation) }
    instance = described_class.new(discovery: { directories: [], home: @directory, cwd: @directory }, env: @env, out: @out, error: @error, input: StringIO.new,
      connector_factory: factory, executor: executor)
    args = [ "--config", @config, "--env-file", @envfile, "--json" ]
    summaries = 2.times.map do
      @out.truncate(0)
      @out.rewind
      expect(instance.run(args)).to eq(1)
      JSON.parse(@out.string)
    end
    expect(summaries.map { |summary| summary.fetch("completed") }).to eq([ 2, 2 ])
    expect(summaries.map { |summary| summary.fetch("directory") }.uniq.size).to eq(2)
    saved = summaries.to_h do |summary|
      path = File.join(summary.fetch("directory"), "summary.json")
      [ path, File.binread(path) ]
    end
    @out.truncate(0)
    @out.rewind
    expect(instance.run([ "--config", File.join(@directory, "missing.yml"), "--env-file", @envfile ])).to eq(2)
    expect(@out.string).to eq("")
    saved.each { |path, bytes| expect(File.binread(path)).to eq(bytes) }
  end

  it "rejects device credentials before showing public configuration" do
    config(devices: [ { "host" => "192.0.2.10", "password" => "private-device-secret" } ])
    expect(run_example(runner, "--show-config")).to eq(2)
    expect(@out.string).to eq("")
    expect(@error.string).not_to include("private-device-secret")
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
    factory = lambda do |_device, settings|
      expect(settings).to include(username: "fixture-user", password: 'fixture#with$dollar')
      connector = double("connector", platform: :cisco_nxos)
      allow(connector).to receive(:open).and_yield(FixtureSession.new)
      connector
    end
    expect(run_example(runner(factory: factory))).to eq(0)
    expect(@env).to eq("NC_DEVICE_USERNAME" => "fixture-user")
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
    expect(Dir["#{directory}/evidence/*.json"].size).to eq(2)
    report = JSON.parse(File.read("#{directory}/evidence/LEAF-01-192.0.2.10.json"))
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
    expect(Dir["#{@directory}/reports/*/evidence/*.json"].size).to eq(2)
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
    inventory = Struct.new(:devices).new([
      { "ip" => "192.0.2.10", "vendor" => "Cisco", "os" => "NX-OS", "name" => "LEAF-01" },
      { "ip" => "192.0.2.11", "vendor" => "H3C" }
    ])
    allow_any_instance_of(Net::Connector::Netdisco::Settings).to receive(:inventory).and_return(inventory)
    @env.clear
    expect(run_example(runner, "--inventory-only", "--json")).to eq(0)
    expect(JSON.parse(@out.string).map { |device| device.fetch("host") }).to eq([ "192.0.2.10" ])
  end

  it "reports inventory failures without retaining private error messages" do
    require "net/connector/netdisco"
    source = File.join(@directory, "netdisco.yml")
    File.write(source, YAML.dump("netdisco" => { "url" => "https://netdisco.example" }))
    config(devices: [], netdisco_config: source)
    allow_any_instance_of(Net::Connector::Netdisco::Settings).to receive(:inventory).and_raise(Net::Connector::Netdisco::Inventory::Error, "private-inventory-error")
    expect(run_example(runner, "--inventory-only")).to eq(2)
    expect(@error.string).to include("VXLAN inventory or execution failed")
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
    expect(@out.string).to be_empty
    expect(@error.string).to include("succeeded 0, partial 0, failed 1", "result incomplete")
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
    expect(@error.string).to include("cancelled", "report")
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
