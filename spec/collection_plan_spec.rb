# frozen_string_literal: true

require_relative "spec_helper"
require "open3"
require "rbconfig"

RSpec.describe Vxlan::CollectionPlan do
  it "loads its empty-query result without the root entrypoint" do
    code = <<~RUBY
      require "vxlan/collection_plan"
      configuration = Struct.new(:records) { def complete? = true }.new([{ nve: { interface: nil } }])
      plan = Vxlan::CollectionPlan.new(profile: Object.new, configuration: configuration)
      result = plan.parse_many([:nve_peers], "", complete: true, command: "show nve peers").fetch(:nve_peers)
      abort "Missing complete empty evidence" unless result.complete? && result.records.empty? && result.issues == [{ code: :nve_not_configured }]
    RUBY
    output, status = Open3.capture2e(RbConfig.ruby, "-Ilib", "-e", code)
    expect(status.success?).to be(true), output
  end
end
