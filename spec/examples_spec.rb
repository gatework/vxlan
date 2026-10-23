# frozen_string_literal: true

require_relative "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"
require "stringio"
require "json"
require "yaml"
require "fileutils"

RSpec.describe "VXLAN host examples" do
  let(:root) { File.expand_path("..", __dir__) }

  around do |example|
    Dir.mktmpdir("vxlan-examples-") do |sandbox|
      @sandbox = sandbox
      FileUtils.mkdir_p(File.join(sandbox, "examples"))
      FileUtils.ln_s(File.join(root, "lib"), File.join(sandbox, "lib"))
      %w[collect parse].each { |name| FileUtils.cp(File.join(root, "examples", "#{name}.rb"), File.join(sandbox, "examples", "#{name}.rb")) }
      example.run
    end
  end

  # 运行公开入口的隔离副本，防止读取开发者现场配置。
  def invoke(script, *arguments, stdin: "", env: {})
    clean = ENV.keys.grep(/\A(?:VXLAN_|NC_|ND_)/).to_h { |key| [ key, nil ] }
    clean.merge!("HOME" => @sandbox, "XDG_CONFIG_HOME" => File.join(@sandbox, ".config"))
    Open3.capture3(clean.merge(env), RbConfig.ruby, "-I#{root}/lib", File.join(@sandbox, "examples", "#{script}.rb"), *arguments, stdin_data: stdin, chdir: @sandbox)
  end

  it "shows help and examples without reading configuration or loading a live connector" do
    %w[collect parse].each do |script|
      stdout, stderr, status = invoke(script, "--help", env: { "VXLAN_CONFIG" => "/missing/private.yml" })
      expect(status).to be_success, stderr
      expect(stdout).to include("Usage:", "--json", "--examples")
    end
  end

  it "parses stdin with explicit transport completeness and preserves incomplete status" do
    stdout, stderr, status = invoke("parse", "--dimension", "ospf_neighbors", "--complete", "--json", stdin: "Total number of neighbors: 0\n")
    expect(status).to be_success, stderr
    expect(JSON.parse(stdout)).to include("status" => "complete", "records" => [])
    stdout, _stderr, status = invoke("parse", "--dimension", "ospf_neighbors", "--json", stdin: "Total number of neighbors: 0\n")
    expect(status.exitstatus).to eq(1)
    expect(JSON.parse(stdout).fetch("status")).to eq("partial")
  end

  it "creates only missing templates and never copies credential environment values" do
    Dir.mktmpdir do |directory|
      config = File.join(directory, "vxlan.yml")
      envfile = File.join(directory, ".env")
      _stdout, stderr, status = invoke("collect", "--init", "--config", config, "--env-file", envfile,
        env: { "NC_DEVICE_PASSWORD" => "private-fixture" })
      expect(status).to be_success, stderr
      expect(File.read(config)).to include("parallel: 4", "devices: []")
      expect(File.read(envfile)).not_to include("private-fixture")
      File.write(config, "do not overwrite\n")
      invoke("collect", "--init", "--config", config, "--env-file", envfile)
      expect(File.read(config)).to eq("do not overwrite\n")
      expect(File.stat(envfile).mode & 0o777).to eq(0o600)
    end
  end

  it "reports missing config without prompting or creating files in automation" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "missing.yml")
      _stdout, stderr, status = invoke("collect", "--config", path, "--non-interactive")
      expect(status.exitstatus).to eq(2)
      expect(stderr).to include("configuration file does not exist", path)
      expect(File.exist?(path)).to be(false)
    end
  end
  it "initializes recognized public parameters without credentials and rejects invalid parallelism" do
    Dir.mktmpdir do |directory|
      config = File.join(directory, "vxlan.yml")
      envfile = File.join(directory, ".env")
      _stdout, _stderr, status = invoke("collect", "--init", "--config", config, "--env-file", envfile, "-p", "501")
      expect(status.exitstatus).to eq(2)
      expect(File.exist?(config)).to be(false)
      _stdout, stderr, status = invoke("collect", "--init", "--config", config, "--env-file", envfile, "-p", "8", "--fabric", "LAB")
      expect(status).to be_success, stderr
      expect(YAML.safe_load_file(config)).to include("parallel" => 8, "fabric" => "LAB")
    end
  end
end
