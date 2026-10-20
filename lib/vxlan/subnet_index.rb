# frozen_string_literal: true

require "ipaddr"
require "ctx_parser/immutable"

module Vxlan
  # 单设备 SVI 网段索引；按 VRF 和地址族查重叠，保留接口顺序和重复来源。
  class SubnetIndex
    Entry = Data.define(:interface, :vni, :address, :position, :first, :prefix)
    private_constant :Entry

    # 仅保存查询所需的独立事实；未解析地址不能作为无重叠证据。
    def initialize(config)
      groups, invalid = {}, {}
      position = 0
      config.fetch("interfaces", {}).each do |name, svi|
        next unless name.match?(/\AVlan\d+\z/)
        vni = config.fetch("vlan_vnis", {})[name.delete_prefix("Vlan")]
        svi.fetch("addresses", []).each do |address|
          fields = CtxParser::Immutable.copy([ name, vni, address ])
          network = parse_network(address)
          entry = Entry.new(*fields, position, network&.to_i, network&.prefix)
          position += 1
          if network
            ((groups[svi["vrf"]] ||= {})[network.ipv4?] ||= []) << entry
          else
            (invalid[svi["vrf"]] ||= []) << entry
          end
        end
      end
      @groups = groups.transform_values do |families|
        families.transform_values do |entries|
          prefixes = entries.group_by(&:prefix).transform_values { |rows| rows.group_by(&:first).transform_values(&:freeze).freeze }
          { ordered: entries.sort_by(&:first).freeze, prefixes: prefixes.freeze }.freeze
        end.freeze
      end.freeze
      @invalid = invalid.transform_values(&:freeze).freeze
      freeze
    end

    # 同业务 VNI 和明确排除的本机接口不构成冲突；其他匹配范围保留完整地址证据。
    def conflicts(address:, vrf:, vni:, except_interface: nil)
      network = IPAddr.new(address)
      @invalid.fetch(vrf, []).each do |entry|
        IPAddr.new(entry.address) if relevant?(entry, vni, except_interface)
      end
      group = @groups.dig(vrf, network.ipv4?)
      return [] unless group

      entries = overlapping(group, network).select { |entry| relevant?(entry, vni, except_interface) }
      entries.sort_by!(&:position)
      entries.group_by(&:interface).map do |name, rows|
        { interface: name, vni: rows.first.vni, value: rows.map(&:address) }
      end
    end

    private

    # 非法地址只在相关查询中重新拒绝，不能让另一 VRF 的未使用事实改变原有边界。
    def parse_network(address)
      IPAddr.new(address)
    rescue ArgumentError
      nil
    end

    # 区间起点命中的子网配合有限个祖先前缀，覆盖相等、包含和被包含的网段。
    def overlapping(group, network)
      first, last = network.to_i, network.to_range.last.to_i
      ordered = group.fetch(:ordered)
      left = ordered.bsearch_index { |entry| entry.first >= first } || ordered.size
      right = ordered.bsearch_index { |entry| entry.first > last } || ordered.size
      entries = ordered[left...right]
      width = network.ipv4? ? 32 : 128
      group.fetch(:prefixes).each do |prefix, subnets|
        next unless prefix < network.prefix
        shift = width - prefix
        ancestor = (first >> shift) << shift
        entries.concat(subnets.fetch(ancestor, [])) unless ancestor == first
      end
      entries
    end

    # 相同 VNI 与排除接口的事实保留在索引中，只在本次查询中排除。
    def relevant?(entry, vni, except_interface)
      entry.vni != vni && entry.interface != except_interface
    end
  end
end
