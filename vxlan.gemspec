# frozen_string_literal: true

require_relative "lib/vxlan/version"

Gem::Specification.new do |spec|
  spec.name = "vxlan"
  spec.version = Vxlan::VERSION
  spec.authors = [ "Gatework contributors" ]
  spec.summary = "Parse and collect Cisco NX-OS VXLAN evidence."
  spec.description = "Independent configuration and runtime parsers for VXLAN fabrics, with immutable snapshots and injected collection sessions."
  spec.homepage = "https://github.com/gatework/vxlan"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0.6"
  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "documentation_uri" => "#{spec.homepage}#readme",
    "allowed_push_host" => "https://rubygems.org",
    "rubygems_mfa_required" => "true"
  }
  # 显式限定打包文件，排除设备回显、凭据、测试夹具和构建产物。
  spec.files = Dir.chdir(__dir__) { Dir["lib/**/*.rb", "examples/**/*.rb", "lib/vxlan/cli/templates/*", "bin/vxlan", "bin/README.md", "examples/README.md", "docs/**/*.md", "README*.md", "CHANGELOG.md", "LICENSE"].sort }
  spec.require_paths = [ "lib" ]
  spec.bindir = "bin"
  spec.executables = [ "vxlan" ]

  spec.add_dependency "ctx_parser", "~> 0.2.0"
  spec.add_dependency "ctx_driver", "~> 0.2.0"
  spec.add_dependency "digest"
  spec.add_dependency "ipaddr"
  %w[json optparse yaml fileutils tempfile time].each { |name| spec.add_dependency name }
end
