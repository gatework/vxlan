# frozen_string_literal: true

require "forwardable"
require "ctx_runner/snapshot"
require_relative "observation"
require_relative "parser_registry"

module Vxlan
  # 领域组合公共快照，身份、维度、时间及采集结论共用同一契约。
  class Snapshot
    include CtxRunner::Document::Value
    extend Forwardable
    def_delegators :@snapshot, :target, :observations, :observed_at, :issues, :collection_status,
      :observation, :complete?, :same_target?
    attr_reader :fabric_key

    def initialize(target:, fabric_key:, observations:, observed_at:, issues: [])
      unless fabric_key.is_a?(String) && !fabric_key.strip.empty? && !/[\x00-\x1f\x7f]/.match?(fabric_key)
        raise ArgumentError, "Fabric identity must be nonempty text"
      end
      @fabric_key = fabric_key.dup.freeze
      @snapshot = CtxRunner::Snapshot.new(target: target, observations: observations, observed_at: observed_at,
        names: CiscoNxos::Profile::COMMANDS.keys, issues: issues)
      freeze
    end

    def to_h = @snapshot.to_h.merge(fabric_key: fabric_key)
    def inspect = "#<#{self.class.name} collection_status=#{collection_status}>"
    alias to_s inspect
    def pretty_print(printer) = printer.text(inspect)
  end
end
