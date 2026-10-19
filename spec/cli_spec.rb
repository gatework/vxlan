# frozen_string_literal: true

require_relative "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"
require "json"
require "yaml"

RSpec.describe "VXLAN installed command" do
  let(:root) { File.expand_path("..", __dir__) }

  def command(*args, directory: root, stdin: "", env: {})
    Open3.capture3({ "VXLAN_CONFIG" => nil }.merge(env), RbConfig.ruby, "-I#{root}/lib", "#{root}/bin/vxlan", *args,
      chdir: directory, stdin_data: stdin)
  end

  it "runs directly from the source bin directory without Bundler or RUBYLIB" do
    clean_env = ENV.keys.grep(/\A(?:BUNDLE_|BUNDLER_|RUBY)/).to_h { |key| [ key, nil ] }
    %w[--help --version].each do |argument|
      stdout, stderr, status = Open3.capture3(clean_env, RbConfig.ruby, "vxlan", argument, chdir: File.join(root, "bin"))
      expect(status).to be_success, stderr
      expect(stdout).to include(argument == "--version" ? Vxlan::VERSION : "vxlan collect")
    end
  end

  it "dispatches help, version and unknown commands without configuration" do
    stdout, stderr, status = command("--help")
    expect(status).to be_success, stderr
    expect(stdout).to include("vxlan collect", "vxlan parse")
    stdout, stderr, status = command("--version")
    expect(status).to be_success, stderr
    expect(stdout.strip).to eq(Vxlan::VERSION)
    _stdout, stderr, status = command("unknown")
    expect(status.exitstatus).to eq(2)
    expect(stderr).to include("--help")
  end

  it "parses evidence through the installed entry point" do
    stdout, stderr, status = command("parse", "--dimension", "ospf_neighbors", "--complete", "--json", stdin: "Total number of neighbors: 0\n")
    expect(status).to be_success, stderr
    expect(JSON.parse(stdout)).to include("status" => "complete", "records" => [])
  end

  it "loads the library and CLI without the connector or executing a command" do
    program = 'require "vxlan/cli"; abort if defined?(Net::Connector); abort if $LOADED_FEATURES.any? { |f| f.include?("vxlan/cli/collect") }'
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I#{root}/lib", "-e", program)
    expect(status).to be_success, stderr
    expect(stdout).to eq("")
  end
  it "initializes in the invocation directory and preserves existing files" do
    Dir.mktmpdir do |directory|
      stdout, stderr, status = command("collect", "--init", "--non-interactive", directory: directory)
      expect(status).to be_success, stderr
      config = File.join(directory, "vxlan.yml")
      env_file = File.join(directory, ".env")
      expect(File).to exist(env_file)
      expect(YAML.safe_load_file(config).fetch("directory")).to eq(File.join(File.realpath(directory), "vxlans"))
      expect(File.stat(config).mode & 0o777).to eq(0o600)
      File.write(config, "preserve me")
      command("collect", "--init", directory: directory)
      expect(File.read(config)).to eq("preserve me")
      expect(stdout).to include(File.join(File.realpath(directory), "vxlan.yml"))
    end
  end

  it "resolves YAML paths beside the config independently of cwd" do
    Dir.mktmpdir do |directory|
      config = File.join(directory, "vxlan.yml")
      File.write(config, YAML.dump("devices" => [], "directory" => "reports", "ssh" => { "known_hosts" => "keys" }))
      stdout, stderr, status = command("collect", "--config", config, "--show-config")
      expect(status).to be_success, stderr
      values = JSON.parse(stdout)
      expect(values.fetch("directory")).to eq(File.join(directory, "reports"))
      expect(values.dig("ssh", "known_hosts")).to eq(File.join(directory, "keys"))
    end
  end

  it "keeps source examples relative to the project root" do
    Dir.mktmpdir do |directory|
      config = File.join(directory, "vxlan.yml")
      File.write(config, YAML.dump("devices" => [], "directory" => "examples/vxlans"))
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I#{root}/lib", "#{root}/examples/collect.rb", "--config", config, "--show-config", chdir: directory)
      expect(status).to be_success, stderr
      expect(JSON.parse(stdout).fetch("directory")).to eq(File.join(root, "examples/vxlans"))
    end
  end
  it "supports the reference examples help and preview conventions" do
    %w[collect parse].each do |name|
      %w[-h --help-all --examples].each do |flag|
        stdout, stderr, status = command(name, flag)
        expect(status).to be_success, stderr
        expect(stdout).to include("vxlan #{name}")
      end
    end
    Dir.mktmpdir do |directory|
      config = File.join(directory, "vxlan.yml")
      File.write(config, YAML.dump("devices" => [ { "host" => "192.0.2.10" } ]))
      stdout, stderr, status = command("collect", "--config", config, "--env-file", "missing.env", "--plan", "--json", "--no-progress")
      expect(status).to be_success, stderr
      expect(JSON.parse(stdout).map { |device| device.fetch("host") }).to eq([ "192.0.2.10" ])
      expect(stderr).to eq("")
      expect(Dir).not_to exist(File.join(directory, "vxlans"))
    end
  end

  it "explains initialization and rejects forced interaction in automation" do
    Dir.mktmpdir do |directory|
      stdout, stderr, status = command("collect", "--init", "--non-interactive", directory: directory)
      expect(status).to be_success, stderr
      expect(stdout).to include("本次未读取清单、未连接设备", "再次运行")
      _stdout, stderr, status = command("collect", "--interactive", "--config", "missing.yml", directory: directory)
      expect(status.exitstatus).to eq(2)
      expect(stderr).to include("--interactive 需要交互终端")
    end
  end
  it "uses the default config when VXLAN_CONFIG is blank in the process or env file" do
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "vxlan.yml"), YAML.dump("devices" => [ { "host" => "192.0.2.10" } ]))
      _stdout, stderr, status = command("collect", "--plan", directory: directory, env: { "VXLAN_CONFIG" => "   " })
      expect(status).to be_success, stderr
      File.write(File.join(directory, ".env"), "VXLAN_CONFIG='   '\n")
      _stdout, stderr, status = command("collect", "--plan", directory: directory)
      expect(status).to be_success, stderr
    end
  end
end
