# frozen_string_literal: true

require "ctx_runner/fingerprint"
require "ipaddr"
require "ctx_parser/immutable"
require_relative "acl_policy"

module Vxlan
  # 一个已校验、不可变的业务增量；命令、适用前提和回读由同一对象负责。
  class ChangePlan
    FIELDS = %w[kind vlan vni].freeze
    EMPTY_ADDRESSES = [].freeze
    private_constant :EMPTY_ADDRESSES
    attr_reader :commands, :rollback

    # 类型判别只发生在输入边界，不接受任意脚本或未声明字段。
    def self.build(change)
      raise ArgumentError, "增量须为映射" unless change.is_a?(Hash)
      case change["kind"]
      when "vlan_vni_add" then VlanVni.new(change)
      when "svi_gateway_add" then SviGateway.new(change)
      when "svi_acl" then SviAcl.new(change)
      else raise ArgumentError, "不支持的增量类型"
      end
    end

    # 审查中的未知或冲突仍为待核实建议，不能构造可执行计划。
    def self.candidate(change, config:)
      plan = build(change)
      plan if plan.eligible?(config)
    rescue ArgumentError
      nil
    end

    # 构造时一次校验和渲染，随后调用者不能改变已确认的参数或命令。
    def initialize(change)
      raise ArgumentError, "请使用 ChangePlan.build 构造业务增量" if instance_of?(ChangePlan)
      unless change.is_a?(Hash) && change.keys.all?(String) && (change.keys - self.class::FIELDS).empty? && change["kind"] == self.class::KIND
        raise ArgumentError, "增量字段无效"
      end
      @change = CtxParser::Immutable.copy(change)
      validate_parameters!
      @commands, @rollback = CtxParser::Immutable.copy(render)
      freeze
    end

    # 报告边界保持普通数据及原有指纹，不引入对象序列化格式。
    def to_h = @change

    # 不完整事实不能满足动态前提；输入错误不能变成肯定结果。
    def eligible?(config)
      config.is_a?(Hash) && eligible_state?(config) == true
    rescue ArgumentError, KeyError, TypeError
      false
    end

    # 只允许从合格起点到目标状态；其余已建模业务事实必须完整保留。
    def satisfied?(after, before:)
      return false unless eligible?(before) && after.is_a?(Hash) && mapped_svi(after)
      preserved_context(before) == preserved_context(after) && target_state?(after) == true
    rescue ArgumentError, KeyError, TypeError
      false
    end

    private

    # 三种动作均定位已有 L2 业务，VLAN/VNI 不从字符串或名称猜测。
    def validate_parameters!
      raise ArgumentError, "VLAN 无效" unless @change["vlan"].is_a?(Integer) && @change["vlan"].between?(1, 4094)
      raise ArgumentError, "VNI 无效" unless @change["vni"].is_a?(Integer) && @change["vni"].between?(1, 16_777_215)
    end

    # 网关相关增量必须携带明确租户及单个已验证 IPv4 前缀。
    def validate_gateway!
      address = @change["address"]
      unless @change["vrf"].is_a?(String) && !@change["vrf"].empty? && address.is_a?(String) &&
          address.match?(/\A\d{1,3}(?:\.\d{1,3}){3}\/\d{1,2}\z/) && IPAddr.new(address).ipv4?
        raise ArgumentError, "缺少已验证的业务网关"
      end
    end

    # 目标接口由已验证 VLAN 唯一定位，不接受自由接口表达式。
    def interface = "Vlan#{@change['vlan']}"

    # 关联存在且未指向其他业务时才有可变更的 SVI。
    def mapped_svi(config)
      config.dig("interfaces", interface) if config.fetch("vlan_vnis", {})[@change["vlan"].to_s] == @change["vni"]
    end

    # 网关增量不能改租户、Anycast 模式或与本机其他业务网段重叠。
    def gateway_context?(config)
      target_interface = interface
      svi = config.dig("interfaces", target_interface)
      return false unless svi && svi["anycast"] == true && svi["vrf"] == @change["vrf"]
      network = IPAddr.new(@change.fetch("address"))
      config.fetch("interfaces", {}).each do |name, other|
        next if name == target_interface || other["vrf"] != @change["vrf"]
        return false if other.fetch("addresses", EMPTY_ADDRESSES).any? do |address|
          candidate = IPAddr.new(address)
          network.include?(candidate) || candidate.include?(network)
        end
      end
      true
    end

    # 元数据与可推导事实不参与漂移比较；每种动作只移除其允许变化的字段。
    def preserved_context(config)
      context = CtxRunner::Fingerprint.canonical(config).except("config_digest", "review_status", "review_findings", "segments", "unnumbered_addresses")
      context.fetch("acls", {}).transform_values! { |entries| AclPolicy.rules(entries) }
      remove_changed_fields(context)
      context
    end
  end
end

require_relative "change_plan/vlan_vni"
require_relative "change_plan/svi_gateway"
require_relative "change_plan/svi_acl"
