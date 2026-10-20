# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"

# 在临时源码副本中植入已定义的契约错误；原工作树与本地配置不参与写入。
mutations = JSON.parse(<<~'JSON')
[
  {
    "id": "non-assertion-control",
    "file": "lib/vxlan/cisco_nxos/parsers/show_bgp_l2vpn_evpn_summary.rb",
    "find": "if counts.sum > peer[:prefixes_received]",
    "replacement": "if raise(NoMethodError, \"verification-sentinel\")",
    "spec": "spec/evidence_contract_spec.rb",
    "control": true
  },
  {
    "id": "prefix-statistics-upper-bound",
    "file": "lib/vxlan/cisco_nxos/parsers/show_bgp_l2vpn_evpn_summary.rb",
    "find": "if counts.sum > peer[:prefixes_received]",
    "replacement": "if false",
    "spec": "spec/evidence_contract_spec.rb"
  },
  {
    "id": "canonical-neighbor-key",
    "file": "lib/vxlan/cisco_nxos/syntax/routing.rb",
    "find": "name = neighbor_keys[canonical] ||= name",
    "replacement": "neighbor_keys[canonical] ||= name",
    "spec": "spec/evidence_contract_spec.rb"
  },
  {
    "id": "checkpoint-bypass",
    "file": "lib/vxlan/cli/report.rb",
    "find": "publish(\"summary.json\", checkpoint_body)",
    "replacement": "nil",
    "spec": "spec/cli/report_spec.rb"
  },
  {
    "id": "committed-recovery-bypass",
    "file": "lib/vxlan/cli/report.rb",
    "find": "restore_checkpoint(checkpoint_body) if error.committed?",
    "replacement": "nil",
    "spec": "spec/cli/report_spec.rb"
  },
  {
    "id": "change-input-ownership",
    "file": "lib/vxlan/change_plan.rb",
    "find": "@change = CtxParser::Immutable.copy(change)",
    "replacement": "@change = change",
    "spec": "spec/change_plan_value_spec.rb"
  },
  {
    "id": "eligible-readback-origin",
    "file": "lib/vxlan/change_plan.rb",
    "find": "return false unless eligible?(before) && after.is_a?(Hash) && mapped_svi(after)",
    "replacement": "return false unless after.is_a?(Hash) && mapped_svi(after)",
    "spec": "spec/change_plan_value_spec.rb"
  },
  {
    "id": "acl-forwarding-order",
    "file": "lib/vxlan/acl_policy.rb",
    "find": "entries.sort_by { |entry| entry.fetch(\"sequence\") }",
    "replacement": "entries.sort_by { |entry| entry.fetch(\"expression\") }",
    "spec": "spec/acl_policy_spec.rb"
  },
  {
    "id": "execution-starting-snapshot",
    "file": "lib/vxlan/cli/apply.rb",
    "find": "before = CtxParser::Immutable.copy(session.read_configuration)",
    "replacement": "before = session.read_configuration",
    "spec": "spec/cli/apply_spec.rb"
  }
]
JSON
root = File.expand_path("..", __dir__)
domain = "vxlan"
boot = <<~'RUBY'
  require "bundler/setup"
  copy, domain = ARGV.shift(2)
  copy = File.realpath(copy)
  $LOAD_PATH.unshift(File.join(copy, "lib"))
  require domain
  abort "Wrong mutation source" unless $LOADED_FEATURES.include?(File.join(copy, "lib", "#{domain}.rb"))
  require "rspec/core"
  exit RSpec::Core::Runner.run([ "--options", File::NULL, "--format", "json", *ARGV ])
RUBY
results = []
baseline = nil
Dir.mktmpdir("evidence-mutations-") do |copy|
  %w[lib spec].each { |name| FileUtils.cp_r(File.join(root, name), File.join(copy, name)) }
  run = lambda do |specs|
    output, error, status = Open3.capture3({ "BUNDLE_GEMFILE" => File.join(root, "Gemfile"), "RUBYOPT" => nil },
      RbConfig.ruby, "-e", boot, copy, domain, *specs.map { |spec| File.join(copy, spec) }, chdir: root)
    abort "Mutation subprocess did not run: #{error}" if output.empty?
    data = JSON.parse(output)
    summary = data.fetch("summary")
    abort "Invalid mutation run" unless summary.fetch("example_count").positive? && summary.fetch("errors_outside_of_examples_count").zero?
    failures = data.fetch("examples").select { |example| example.fetch("status") == "failed" }
    assertions, unexpected = failures.partition do |example|
      %w[RSpec::Expectations::ExpectationNotMetError RSpec::Mocks::MockExpectationError].include?(example.fetch("exception").fetch("class"))
    end
    [ status, summary, assertions.size, unexpected.map { |example| example.fetch("exception").fetch("class") } ]
  end
  baseline_status, baseline = run.call(mutations.map { |mutation| mutation.fetch("spec") }.uniq)
  abort "Baseline contracts failed" unless baseline_status.success? && baseline.fetch("failure_count").zero?
  mutations.each do |mutation|
    file = File.join(copy, mutation.fetch("file"))
    original = File.read(file)
    target = mutation.fetch("find")
    abort "Mutation target changed: #{mutation.fetch('id')}" unless original.scan(Regexp.new(Regexp.escape(target))).size == 1
    begin
      File.write(file, original.sub(target, mutation.fetch("replacement")))
      status, summary, assertions, unexpected = run.call([ mutation.fetch("spec") ])
      detected = !status.success? && assertions.positive? && unexpected.empty?
      results << { id: mutation.fetch("id"), detected: detected, control: mutation.fetch("control", false),
        control_rejected: mutation["control"] && !detected && unexpected.any?, examples: summary.fetch("example_count"),
        assertion_failures: assertions, unexpected_failures: unexpected.tally }
    ensure
      File.write(file, original)
    end
  end
end
puts JSON.pretty_generate(runtime: RUBY_VERSION, baseline: baseline, mutants: results)
exit(results.all? { |result| result.fetch(:control) ? result.fetch(:control_rejected) : result.fetch(:detected) } ? 0 : 1)
