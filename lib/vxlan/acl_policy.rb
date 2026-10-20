# frozen_string_literal: true

require "ipaddr"
require "ctx_parser/immutable"

module Vxlan
  # ACL 的业务身份是有序转发规则与引用对象，序号和备注不改变策略。
  AclPolicy = Data.define(:rules, :address_groups) do
    # 策略与解析输入解除共享，比较和导出都使用同一份不可变事实。
    def initialize(rules:, address_groups:)
      super(rules: CtxParser::Immutable.copy(rules), address_groups: CtxParser::Immutable.copy(address_groups))
    end

    # 未采集、非法或未支持的规则保持未知，完整空定义仍可单独表达。
    def self.rules(entries)
      return nil unless entries.is_a?(Array) && entries.all? do |entry|
        entry.is_a?(Hash) && entry["sequence"].is_a?(Integer) && entry["sequence"].between?(1, 4_294_967_295) &&
          %w[permit deny remark].include?(entry["action"]) && entry["expression"].is_a?(String)
      end
      return nil unless entries.map { |entry| entry["sequence"] }.uniq.size == entries.size
      entries.sort_by { |entry| entry.fetch("sequence") }.reject { |entry| entry["action"] == "remark" }.map { |entry| entry.slice("action", "expression") }
    end

    # 未知端口组或时间范围不能证明策略一致；已解析地址组按成员集合比较。
    def self.resolve(config, entries)
      rules = self.rules(entries)
      return nil unless rules
      return nil if rules.any? { |rule| rule["expression"].match?(/\b(?:portgroup|object-group|time-range)\b/) }
      names = rules.flat_map { |rule| rule["expression"].scan(/\baddrgroup\s+(\S+)/).flatten }.uniq.sort
      groups = names.to_h do |name|
        members = config.fetch("address_groups", {})[name]
        return nil unless members.is_a?(Array) && members.any? && members.all? { |value| value.is_a?(String) && value.include?("/") && IPAddr.new(value).ipv4? }
        [ name, members.uniq.sort ]
      end
      new(rules: rules, address_groups: groups)
    rescue IPAddr::Error
      nil
    end

    # 新建定义影响本机全部既有引用，审查与动作前后检查共用引用范围。
    def self.bindings(config, name)
      config.fetch("interfaces", {}).flat_map do |interface, values|
        values.fetch("acl_bindings", {}).filter_map { |direction, acl| { "interface" => interface, "direction" => direction } if acl == name }
      end
    end

    # 仅在报告边界转为普通数据，不把 Ruby 对象的 inspect 当成策略摘要。
    def to_h = { "rules" => rules, "address_groups" => address_groups }.freeze
  end
end
