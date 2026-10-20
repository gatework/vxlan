# frozen_string_literal: true

require "ctx_parser/immutable"

module Vxlan
  # 保留命令事实与完整性；默认检查不输出原始配置或凭据。
  Observation = Data.define(:name, :status, :records, :issues, :evidence, :started_at, :completed_at) do
    # 冻结单个维度的记录、状态及诊断元数据。
    def initialize(name:, status:, records: [], issues: [], evidence: [], started_at: nil, completed_at: nil)
      raise ArgumentError, "Observation name must be a symbol" unless name.is_a?(Symbol)
      raise ArgumentError, "Invalid observation status" unless %i[complete partial failed unsupported not_requested].include?(status)
      raise ArgumentError, "Records must be hashes" unless records.is_a?(Array) && records.all? { |row| row.is_a?(Hash) }

      super(name: name, status: status, records: CtxParser::Immutable.copy(records),
        issues: CtxParser::Immutable.copy(issues), evidence: CtxParser::Immutable.copy(evidence),
        started_at: started_at&.dup&.freeze, completed_at: completed_at&.dup&.freeze)
    end

    # 判断所有已选事实是否都有完整证据支持。
    def complete? = status == :complete

    # 展示对象身份与状态，避免泄露原始回显或凭据。
    def inspect = "#<#{self.class.name} name=#{name} status=#{status} records=#{records.size}>"
    alias to_s inspect

    # PP 默认展开 Data 成员，显式沿用脱敏展示。
    def pretty_print(printer) = printer.text(inspect)
  end
end
