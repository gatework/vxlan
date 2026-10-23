# frozen_string_literal: true

require_relative "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"
require "json"
require "yaml"
require "fileutils"

RSpec.describe "VXLAN installed command" do
  let(:root) { File.expand_path("..", __dir__) }

  around do |example|
    Dir.mktmpdir("vxlan-cli-") do |sandbox|
      @sandbox = sandbox
      FileUtils.mkdir_p(File.join(sandbox, "bin"))
      FileUtils.mkdir_p(File.join(sandbox, "home"))
      FileUtils.mkdir_p(File.join(sandbox, "work"))
      FileUtils.cp(File.join(root, "bin/vxlan"), File.join(sandbox, "bin/vxlan"))
      FileUtils.ln_s(File.join(root, "lib"), File.join(sandbox, "lib"))
      example.run
    end
  end

  def isolated_environment
    ENV.keys.grep(/\A(?:VXLAN_|NC_|NETDISCO_|WIRELESS_)/).to_h { |key| [ key, nil ] }.merge(
      "HOME" => File.join(@sandbox, "home"), "XDG_CONFIG_HOME" => File.join(@sandbox, "home/.config"))
  end

  def command(*args, directory: File.join(@sandbox, "work"), stdin: "", env: {})
    Open3.capture3(isolated_environment.merge(env), RbConfig.ruby, "-I#{root}/lib", File.join(@sandbox, "bin/vxlan"), *args,
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

  it "reports a missing collection dependency without a backtrace" do
    program = <<~RUBY
      require "vxlan/cli"
      module Kernel
        alias original_require require
        def require(path)
          raise LoadError, "missing selection" if path == "net/connector/inventory/filters"
          original_require(path)
        end
      end
      exit Vxlan::CLI.run(["collect", "--help"])
    RUBY
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I#{root}/lib", "-e", program)
    expect(status.exitstatus).to eq(2)
    expect(stderr).to include("net-connector")
    expect(stderr).not_to include("LoadError", "<top (required)>")
  end

  it "loads the library and CLI without the connector or executing a command" do
    program = 'require "vxlan/cli"; abort if defined?(Net::Connector); abort if $LOADED_FEATURES.any? { |f| f.include?("vxlan/cli/collect") }'
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I#{root}/lib", "-e", program)
    expect(status).to be_success, stderr
    expect(stdout).to eq("")
  end
  it "initializes in the user configuration directory and preserves existing files" do
    Dir.mktmpdir do |directory|
      stdout, stderr, status = command("collect", "--init", "--non-interactive", directory: directory)
      expect(status).to be_success, stderr
      config = File.join(@sandbox, "home/.config/net-connector/vxlan.yml")
      env_file = File.join(@sandbox, "home/.config/net-connector/.env")
      expect(File).to exist(env_file)
      expect(YAML.safe_load_file(config).fetch("directory")).to eq(File.join(File.realpath(directory), "vxlans"))
      expect(File.stat(config).mode & 0o777).to eq(0o600)
      File.write(config, "preserve me")
      command("collect", "--init", directory: directory)
      expect(File.read(config)).to eq("preserve me")
      expect(stdout).to include(config)
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

  it "resolves source example paths beside their configuration" do
    Dir.mktmpdir do |directory|
      config = File.join(directory, "vxlan.yml")
      File.write(config, YAML.dump("devices" => [], "directory" => "examples/vxlans"))
      example_path = File.join(@sandbox, "bin/collect.rb")
      FileUtils.cp(File.join(root, "examples/collect.rb"), example_path)
      stdout, stderr, status = Open3.capture3(isolated_environment, RbConfig.ruby, "-I#{root}/lib", example_path, "--config", config, "--show-config", chdir: directory)
      expect(status).to be_success, stderr
      expect(JSON.parse(stdout).fetch("directory")).to eq(File.join(directory, "examples/vxlans"))
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
      stdout, stderr, status = command("collect", "--config", config, "--plan", "--json", "--no-progress")
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
      expect(stdout).to include("inventory was not read and no devices were connected", "run again")
      _stdout, stderr, status = command("collect", "--interactive", "--config", "missing.yml", directory: directory)
      expect(status.exitstatus).to eq(2)
      expect(stderr).to include("--interactive requires an interactive terminal")
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
