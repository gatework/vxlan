# frozen_string_literal: true

require "rubygems/package"
require "tmpdir"
require "rbconfig"
require "fileutils"

# 仅验证发布文件与解析后的依赖，避免从工作区加载代码。
artifact = File.expand_path(ARGV.fetch(0))
connector_artifact = ARGV[1] && File.expand_path(ARGV[1])
expect_artifact = ARGV[2] && File.expand_path(ARGV[2])
spec = Gem::Package.new(artifact).spec
abort "Unexpected package" unless spec.name == "vxlan"
abort "Missing CLI guide" unless spec.files.include?("bin/README.md")
abort "Local bin configuration packaged" if spec.files.any? { |path| path.start_with?("bin/") && !%w[bin/vxlan bin/README.md].include?(path) }
abort "Legacy implementation packaged" if spec.files.any? { |path| path.start_with?("examples/support/") }
abort "Unexpected package contents" if spec.files.any? { |path| path.start_with?("spec/", "test/", "storage/", "tmp/") || path.end_with?(".log", ".gem") }
# 本地开发包只使用已安装依赖的缓存，避免重新求解远端依赖或借用开发加载路径。
local_dependencies = []
if connector_artifact
  pending = Gem::Package.new(connector_artifact).spec.runtime_dependencies.dup
  seen = []
  until pending.empty?
    dependency = pending.shift
    next if seen.include?(dependency.name)
    seen << dependency.name
    selected = if dependency.name == "expect-pty" && expect_artifact
      Gem::Package.new(expect_artifact).spec
    else
      Gem::Specification.find_all_by_name(dependency.name, dependency.requirement).max_by(&:version)
    end
    abort "Missing local dependency: #{dependency.name}" unless selected && dependency.matches_spec?(selected)
    cache = dependency.name == "expect-pty" && expect_artifact ? expect_artifact : selected.cache_file
    if File.file?(cache)
      local_dependencies << cache
    elsif !selected.default_gem?
      abort "Missing dependency cache: #{dependency.name}"
    end
    pending.concat(selected.runtime_dependencies)
  end
end

Dir.mktmpdir("gem-install-") do |home|
  env = ENV.to_h.keys.grep(/\A(?:BUNDLE_|BUNDLER_|RUBY|VXLAN_|NC_|ND_)/).to_h { |key| [ key, nil ] }
  env.merge!("GEM_HOME" => home, "GEM_PATH" => home, "RUBYOPT" => nil, "RUBYLIB" => nil, "HOME" => File.join(home, "user"), "XDG_CONFIG_HOME" => File.join(home, "config"))
  local_dependencies.each { |path| FileUtils.cp(path, home) }
  ruby = RbConfig.ruby
  system(env, ruby, "-S", "gem", "install", artifact, "--no-document", exception: true)
  check = <<~RUBY
    require "vxlan"
    require "rbconfig"
    abort "Unexpected Rails dependency" if defined?(Rails)
    loaded = Gem.loaded_specs.fetch("vxlan")
    abort "Loaded checkout instead of package" unless File.realpath(loaded.full_gem_path).start_with?(File.realpath(ENV.fetch("GEM_HOME")) + "/")
    abort "Version mismatch" unless loaded.version.to_s == #{spec.version.to_s.inspect}
    abort "Unexpected connector dependency" if loaded.runtime_dependencies.any? { |dependency| %w[net-connector dotenv].include?(dependency.name) }
    abort "Missing installed CLI guide" unless File.file?(File.join(loaded.full_gem_path, "bin/README.md"))
    abort "Missing executable" unless loaded.executables == [ "vxlan" ]
    change = { "kind" => "svi_gateway_add", "vlan" => 8, "vni" => 10008, "vrf" => "tenant", "address" => "192.0.2.1/24" }
    plan = Vxlan::ChangePlan.build(change)
    before = { "vlan_vnis" => { "8" => 10008 }, "interfaces" => { "Vlan8" => { "vrf" => "tenant", "anycast" => true, "addresses" => [] } } }
    after = { "vlan_vnis" => { "8" => 10008 }, "interfaces" => { "Vlan8" => { "vrf" => "tenant", "anycast" => true, "addresses" => [ "192.0.2.1/24" ] } } }
    change["address"] = "198.51.100.1/24"
    abort "Invalid installed business plan" unless plan.frozen? && plan.to_h.frozen? && plan.commands.frozen? &&
      plan.commands == [ "configure terminal", "interface Vlan8", "  ip address 192.0.2.1/24", "end" ] &&
      plan.eligible?(before) && plan.satisfied?(after, before: before)
    require "fileutils"
    FileUtils.chmod_R("a-w", loaded.full_gem_path)
    command = File.join(ENV.fetch("GEM_HOME"), "bin/vxlan")
    system(command, "--help", exception: true)
    system(command, "--version", exception: true)
    system(command, "review", "--help", exception: true)
    system(command, "apply", "--help", exception: true)
    require "json"
    FileUtils.mkdir_p("saved/evidence")
    File.write("saved/evidence/ac.json", JSON.generate(device: { name: "AC", host: "192.0.2.1", platform: "h3c_wireless" }, snapshot: nil))
    system(command, "review", "--batch", "saved", "--output", "reviews", exception: true)
    abort "Missing installed review artifacts" unless Dir["reviews/*/devices/*.txt"].size == 1
    review_root = Dir["reviews/*"].fetch(0)
    manifest = JSON.parse(File.read(File.join(review_root, "summary.json")))
    abort "Unexpected review layout" unless manifest["layout_version"] == 3 && manifest["reports"].all? { |entry| entry["report"].nil? || File.file?(File.join(review_root, entry["report"])) }
    abort "Redundant empty sidecars" unless Dir[File.join(review_root, "**", "*.cfg")].empty? && Dir[File.join(review_root, "**", "*.cli")].empty?
    abort "Unexpected Markdown" unless Dir[File.join(review_root, "**", "*.md")].empty?
    require "digest"
    plan_file = File.join(review_root, "plan.json")
    abort "Invalid plan checksum" unless File.read(plan_file + ".sha256").strip == Digest::SHA256.file(plan_file).hexdigest
    abort "Missing audit" unless JSON.parse(File.read(plan_file))["audits"].size == 1

    system(command, "collect", "--help-all", exception: true)
    system(command, "parse", "--help-all", exception: true)
    File.write("ospf.txt", "Total number of neighbors: 0\\n")
    system(command, "parse", "--dimension", "ospf_neighbors", "--complete", "--json", "--file", "ospf.txt", exception: true)
    # 离线入口验证后再安装共享配置/联网可选依赖。
    expect_package = #{expect_artifact.inspect}
    system(RbConfig.ruby, "-S", "gem", "install", expect_package, "--local", "--no-document", exception: true) if expect_package
    connector_package = #{connector_artifact.inspect}
    installation = connector_package ? [ connector_package, "--local" ] : [ "net-connector", "--version", "~> 0.14.2" ]
    system(RbConfig.ruby, "-S", "gem", "install", *installation, "--no-document", exception: true)
    system(command, "collect", "--init", "--non-interactive", exception: true)
    config = File.join(ENV.fetch("XDG_CONFIG_HOME"), "net-connector/vxlan.yml")
    env_file = File.join(ENV.fetch("XDG_CONFIG_HOME"), "net-connector/.env")
    abort "Config missing" unless File.file?(config) && File.file?(env_file)
    abort "Initialization wrote into cwd" if File.exist?("vxlan.yml") || File.exist?(".env")
    abort "Unsafe config permissions" unless File.stat(config).mode & 0o777 == 0o600
    require "yaml"
    File.write(config, YAML.dump("devices" => [ { "host" => "192.0.2.10" } ]))
    system(command, "collect", "--plan", "--no-progress", exception: true)
    system(command, "collect", "--plan", "--env-file", "absent.env")
    abort "Missing explicit environment file accepted" unless $?.exitstatus == 2
    load File.join(loaded.full_gem_path, "examples/offline.rb")
    %w[parse collect].each do |name|
      system(RbConfig.ruby, File.join(loaded.full_gem_path, "examples", "\#{name}.rb"), "--help", exception: true)
    end
    FileUtils.chmod_R("u+w", loaded.full_gem_path)
  RUBY
  system(env, ruby, "-e", check, chdir: home, exception: true)
end
