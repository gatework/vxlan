# frozen_string_literal: true

require_relative "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"
require "stringio"
require "json"
require "yaml"

RSpec.describe "VXLAN host examples" do
  let(:root) { File.expand_path("..", __dir__) }

  # 子进程加载公开脚本，验证入口本身而不是复制 OptionParser 行为。
  def invoke(script, *arguments, stdin: "", env: {})
    Open3.capture3(env, RbConfig.ruby, "-I#{root}/lib", "#{root}/examples/#{script}.rb", *arguments, stdin_data: stdin)
  end

  it "shows help and examples without reading configuration or loading a live connector" do
    %w[collect parse].each do |script|
      stdout, stderr, status = invoke(script, "--help", env: { "VXLAN_CONFIG" => "/missing/private.yml" })
      expect(status).to be_success, stderr
      expect(stdout).to include("用法", "--json", "--examples")
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
      expect(stderr).to include("--init")
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
