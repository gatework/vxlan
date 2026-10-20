# frozen_string_literal: true

require_relative "../spec_helper"
require "vxlan/cli/collect"
require "tmpdir"
require "stringio"

RSpec.describe "VXLAN shared configuration sources" do
  around do |example|
    Dir.mktmpdir do |root|
      @root = root
      @system, @user = %w[system user].map { |name| File.join(root, name).tap { |path| Dir.mkdir(path) } }
      example.run
    end
  end

  def options(argv = [], env: {})
    Vxlan::CLI::Options.new(argv, env: env, out: StringIO.new,
      discovery: { directories: [ @system, @user ], cwd: @root, home: @root, script: File.join(@root, "vxlan") }).tap(&:load_environment)
  end

  it "initializes a shared file that reloads with explicit values and source paths" do
    path = File.join(@user, "net-connector.yml")
    directory = File.join(@root, "reports")
    options([ "--init", "--config", path, "--parallel", "9", "--directory", directory ]).initialize_files
    expect(YAML.safe_load_file(path).keys).to eq([ "vxlan" ])

    result = options([ "--config", path ]).load
    expect(result.values).to include("parallel" => 9, "directory" => directory)
    expect(result.sources.fetch("configuration_files")).to eq([ path ])
    expect(result.sources.fetch("fields").fetch("parallel")).to eq(path)
    expect(result.values.fetch("devices")).to eq([])
  end

  it "keeps shared concurrency live after initialization and allows an explicit YAML override" do
    environment = File.join(@user, ".env")
    config = File.join(@user, "vxlan.yml")
    File.write(environment, "NC_PARALLEL=50\n")
    options([ "--init", "--config", config ]).initialize_files
    expect(options.load.values.fetch("parallel")).to eq(50)
    File.write(environment, "NC_PARALLEL=30\n")
    expect(options.load.values.fetch("parallel")).to eq(30)
    data = YAML.safe_load_file(config).merge("parallel" => 7)
    File.write(config, YAML.dump(data))
    expect(options.load.values.fetch("parallel")).to eq(7)
    expect(options(env: { "NC_PARALLEL" => "8" }).load.values.fetch("parallel")).to eq(8)
    expect(options([ "--parallel", "9" ], env: { "NC_PARALLEL" => "8" }).load.values.fetch("parallel")).to eq(9)
  end

  it "does not freeze a common process value because a lower layer has a tool-specific value" do
    environment = File.join(@user, ".env")
    config = File.join(@user, "vxlan.yml")
    File.write(environment, "VXLAN_PARALLEL=4\n")
    options([ "--init", "--config", config ], env: { "NC_PARALLEL" => "50" }).initialize_files
    File.write(environment, "NC_PARALLEL=30\n")
    expect(options.load.values.fetch("parallel")).to eq(30)
  end

  it "shares defaults, replaces device lists, and resolves each path at its own source" do
    File.write(File.join(@system, "net-connector.yml"), YAML.dump("common" => { "ssh" => { "known_hosts" => "keys/hosts" } }))
    File.write(File.join(@system, "vxlan.yml"), YAML.dump("parallel" => 2, "devices" => [ { "host" => "192.0.2.1" } ], "directory" => "reports"))
    File.write(File.join(@user, "vxlan.yml"), YAML.dump("devices" => [ { "host" => "192.0.2.2" } ], "ssh" => { "command_timeout" => 17 }))
    result = options.load
    expect(result.values["devices"].map { |row| row["host"] }).to eq([ "192.0.2.2" ])
    expect(result.values).to include("parallel" => 2, "directory" => File.join(@system, "reports"))
    expect(result.values["ssh"]).to include("known_hosts" => File.join(@system, "keys/hosts"), "command_timeout" => 17)
    expect(result.sources["configuration_files"].size).to eq(3)
  end

  it "applies CLI then process then YAML then dotenv without modifying the process environment" do
    File.write(File.join(@system, ".env"), "VXLAN_PARALLEL=2\nNC_DEVICE_PASSWORD=hidden\n")
    File.write(File.join(@user, "vxlan.yml"), YAML.dump("parallel" => 3))
    env = { "VXLAN_PARALLEL" => "4" }
    expect(options.load.values["parallel"]).to eq(3)
    expect(options(env: env).load.values["parallel"]).to eq(4)
    result = options([ "-p", "5" ], env: env).load
    expect(result.values["parallel"]).to eq(5)
    expect(result.environment["NC_DEVICE_PASSWORD"]).to eq("hidden")
    expect(env).to eq("VXLAN_PARALLEL" => "4")
    expect(result.sources.to_s).not_to include("hidden")
  end

  it "does not activate common dynamic inventory over explicitly selected static devices" do
    File.write(File.join(@system, "net-connector.yml"), YAML.dump("common" => { "netdisco" => { "url" => "https://inventory.example.test" } }))
    File.write(File.join(@user, "vxlan.yml"), YAML.dump("devices" => [ { "host" => "192.0.2.1" } ]))
    result = options.load
    expect(result.values).not_to have_key("netdisco")
    expect(result.values["devices"].size).to eq(1)
  end

  it "uses the same environment-selected inventory source and filters in preview and execution" do
    File.write(File.join(@user, "vxlan.yml"), YAML.dump("netdisco" => { "url" => "https://yaml.example.test" }, "inventory" => { "include_hosts" => [ "192.0.2.1" ] }))
    File.write(File.join(@system, ".env"), "ND_CACHE_DIRECTORY=cache\nND_PAGE_SIZE=invalid\n")
    result = options(env: { "ND_URL" => "https://process.example.test", "NC_INCLUDE_HOSTS" => "192.0.2.2", "ND_PAGE_SIZE" => "5" }).load
    expect(result.values.dig("netdisco", "url")).to eq("https://process.example.test")
    expect(result.values.dig("inventory", "include_hosts")).to eq([ "192.0.2.2" ])
    expect(result.values.dig("netdisco", "cache_directory")).to eq(File.join(@system, "cache"))
    expect(result.netdisco_settings.inventory_options[:url]).to eq(result.values.dig("netdisco", "url"))
    expect(result.netdisco_settings.public_config.dig(:inventory, :include_hosts)).to eq(result.values.dig("inventory", "include_hosts"))
  end

  it "resolves external inventory paths once and previews the frozen effective inventory" do
    inventory = File.join(@system, "inventory.yml")
    File.write(inventory, YAML.dump("netdisco" => { "url" => "https://yaml.example.test", "cache_directory" => "cache" }))
    File.write(File.join(@user, "vxlan.yml"), YAML.dump("netdisco_config" => inventory))
    result = options(env: { "ND_URL" => "https://process.example.test", "ND_API_KEY" => "fixture-only-key" }).load
    File.write(inventory, "invalid: changed mid-batch")
    preview = result.public_values.fetch("inventory_configuration")
    expect(Net::Connector::Netdisco::Inventory::HTTP).to receive(:new).with(hash_including(api_key: "fixture-only-key")).and_call_original
    expect { result.netdisco_settings.inventory }.not_to raise_error
    expect(result.public_values.to_s).not_to include("fixture-only-key")
    expect(preview.dig("netdisco", "url")).to eq("https://process.example.test")
    expect(preview.dig("netdisco", "cache_directory")).to eq(File.join(@system, "cache"))
    expect(result.netdisco_settings.inventory_options[:url]).to eq(preview.dig("netdisco", "url"))
  end

  it "isolates inventory settings from unrelated public environment policies" do
    File.write(File.join(@user, "vxlan.yml"), YAML.dump("netdisco" => { "url" => "https://inventory.example.test" }))
    result = options(env: { "NC_TOPOLOGY_DESCRIPTION_FORMAT" => "unused %{unknown}",
      "NC_TOPOLOGY_PARALLEL" => "unused-invalid", "NC_TFTP_VRFS" => "unused-invalid" }).load
    expect(result.netdisco_settings.inventory_options.fetch(:url)).to eq("https://inventory.example.test")
  end

  it "validates only inventory sections in an external document and retains their source paths" do
    path = File.join(@system, "inventory.yml")
    document = { "netdisco" => { "url" => "https://inventory.example.test", "cache_directory" => "cache" },
      "inventory" => { "include_names" => [ "leaf" ] }, "backup" => { "parallel" => 501 }, "ssh" => "unused-invalid" }
    File.write(path, YAML.dump(document))
    File.write(File.join(@user, "vxlan.yml"), YAML.dump("netdisco_config" => path))
    result = options.load
    expect(result.values.fetch("parallel")).to eq(4)
    expect(result.public_values.fetch("inventory_configuration")).to eq(
      "netdisco" => { "url" => "https://inventory.example.test", "cache_directory" => File.join(@system, "cache") },
      "inventory" => { "include_names" => [ "leaf" ] })
    File.write(path, YAML.dump(document.merge("netdisco" => { "page_size" => 0 })))
    expect { options.load }.to raise_error(ArgumentError, /page_size/)
  end

  it "refuses a missing explicit file instead of falling back to discovered configuration" do
    File.write(File.join(@user, "vxlan.yml"), YAML.dump("parallel" => 3))
    expect { options([ "--config", File.join(@root, "absent.yml") ]).load }.to raise_error(ArgumentError)
  end
end
