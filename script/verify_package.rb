# frozen_string_literal: true

require "rubygems/package"
require "tmpdir"
require "rbconfig"

# 仅验证发布文件与解析后的依赖，避免从工作区加载代码。
artifact = File.expand_path(ARGV.fetch(0))
spec = Gem::Package.new(artifact).spec
abort "Unexpected package" unless spec.name == "vxlan"
abort "Missing CLI guide" unless spec.files.include?("bin/README.md")
abort "Local bin configuration packaged" if spec.files.any? { |path| path.start_with?("bin/") && !%w[bin/vxlan bin/README.md].include?(path) }
abort "Legacy implementation packaged" if spec.files.any? { |path| path.start_with?("examples/support/") }
abort "Unexpected package contents" if spec.files.any? { |path| path.start_with?("spec/", "test/", "storage/", "tmp/") || path.end_with?(".log", ".gem") }
Dir.mktmpdir("gem-install-") do |home|
  env = ENV.to_h.keys.grep(/\A(?:BUNDLE_|BUNDLER_|RUBY|VXLAN_)/).to_h { |key| [ key, nil ] }
  env.merge!("GEM_HOME" => home, "GEM_PATH" => home, "RUBYOPT" => nil, "RUBYLIB" => nil, "NC_PARALLEL" => nil)
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
    require "fileutils"
    FileUtils.chmod_R("a-w", loaded.full_gem_path)
    command = File.join(ENV.fetch("GEM_HOME"), "bin/vxlan")
    system(command, "--help", exception: true)
    system(command, "--version", exception: true)
    system(command, "collect", "--help-all", exception: true)
    system(command, "parse", "--help-all", exception: true)
    File.write("ospf.txt", "Total number of neighbors: 0\\n")
    system(command, "parse", "--dimension", "ospf_neighbors", "--complete", "--json", "--file", "ospf.txt", exception: true)
    system(command, "collect", "--init", "--non-interactive", exception: true)
    abort "Config missing" unless File.file?("vxlan.yml") && File.file?(".env")
    abort "Unsafe config permissions" unless File.stat("vxlan.yml").mode & 0o777 == 0o600
    # 网络依赖保持可选；静态预览通过不存在的 env-file 避免要求 dotenv。
    require "yaml"
    File.write("vxlan.yml", YAML.dump("devices" => [ { "host" => "192.0.2.10" } ]))
    system(command, "collect", "--plan", "--no-progress", "--env-file", "absent.env", exception: true)
    load File.join(loaded.full_gem_path, "examples/offline.rb")
    %w[parse collect].each do |name|
      system(RbConfig.ruby, File.join(loaded.full_gem_path, "examples", "\#{name}.rb"), "--help", exception: true)
    end
    FileUtils.chmod_R("u+w", loaded.full_gem_path)
  RUBY
  system(env, ruby, "-e", check, chdir: home, exception: true)
end
