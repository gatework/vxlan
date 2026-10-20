# frozen_string_literal: true

module Vxlan
  class Config
    # 设备快照只有唯一且完成配置审查的记录，才能用于缺失推导或变更计划。
    module Evidence
      # 外层采集成功不能覆盖记录层的部分解析或多份配置歧义。
      def self.complete_record(document)
        observation = document&.dig("snapshot", "dimensions", "configuration")
        return unless observation && observation["status"] == "complete"
        records = observation["records"]
        return unless records.is_a?(Array) && records.one?
        record = records.first
        record if record.is_a?(Hash) && record["review_status"] == "complete"
      end
    end
  end
end
