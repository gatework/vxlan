# frozen_string_literal: true

require "ctx_parser/immutable"
require_relative "observation"
require_relative "parser_registry"

module Vxlan
  # 携带单设备 Fabric 身份及观测结果，不管理资产清单。
  Snapshot = Data.define(:target, :fabric_key, :observations, :observed_at) do
    # 事实由不可变领域观测持有；仅复制维度选择，不重复复制事实。
    def initialize(target:, fabric_key:, observations:, observed_at:)
      unless observations.is_a?(Hash) && observations.all? { |name, value| value.is_a?(Observation) && value.name == name }
        raise ArgumentError, "Dimensions must match their observations"
      end

      super(target: CtxParser::Immutable.copy(target), fabric_key: CtxParser::Immutable.copy(fabric_key),
        observations: observations.to_h { |name, value| [ name, value ] }.freeze, observed_at: observed_at&.dup&.freeze)
    end

    # 未请求的已知维度保留明确状态；未知维度属于调用错误。
    def observation(name)
      unless name == :collection || CiscoNxos::Profile::COMMANDS.key?(name)
        raise ArgumentError, "Unknown VXLAN dimension"
      end
      observations.fetch(name) { Observation.new(name: name, status: :not_requested) }
    end

    # 报告格式独立于 Ruby 成员命名，已有离线证据继续使用 dimensions。
    def to_h = super.except(:observations).merge(dimensions: observations)

    # 判断所有已选事实是否都有完整证据支持。
    def complete?
      selected = observations.values.reject { |dimension| dimension.status == :not_requested }
      selected.any? && selected.all?(&:complete?)
    end

    # 展示对象身份与状态，避免泄露原始回显或凭据。
    def inspect = "#<#{self.class.name} fabric=#{fabric_key.inspect} complete=#{complete?}>"
    alias to_s inspect

    # PP 默认展开 Data 成员，显式沿用脱敏展示。
    def pretty_print(printer) = printer.text(inspect)
  end
end
