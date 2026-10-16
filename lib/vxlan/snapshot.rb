# frozen_string_literal: true

require "ctx_parser/immutable"

module Vxlan
  # 携带单设备 Fabric 身份及观测结果，不管理资产清单。
  Snapshot = Data.define(:target, :fabric_key, :dimensions, :observed_at) do
    # 事实由不可变领域观测持有；仅复制维度选择，不重复复制事实。
    def initialize(target:, fabric_key:, dimensions:, observed_at:)
      super(target: CtxParser::Immutable.copy(target), fabric_key: CtxParser::Immutable.copy(fabric_key),
        dimensions: dimensions.dup.freeze, observed_at: observed_at&.dup&.freeze)
    end

    # 判断所有已选事实是否都有完整证据支持。
    def complete?
      selected = dimensions.values.reject { |dimension| dimension.status == :not_requested }
      selected.any? && selected.all?(&:complete?)
    end

    # 展示对象身份与状态，避免泄露原始回显或凭据。
    def inspect = "#<#{self.class.name} fabric=#{fabric_key.inspect} complete=#{complete?}>"
  end
end
