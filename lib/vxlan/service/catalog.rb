# frozen_string_literal: true

require "json"

module Vxlan
  module Service
    # L2 业务由 VLAN、NVE、EVPN 的联合事实识别；缺一个环节仍是已开始部署。
    class Catalog
      # 配置完整性由调用方保证，目录本身不读取设备或推断部署意图。
      def initialize(configs)
        @configs = configs
      end

      # 一个 VNI 可有多个本地 VLAN 事实，交给审查明确报告歧义。
      def services
        result = Hash.new { |hash, vni| hash[vni] = [] }
        @configs.each do |host, config|
          mappings = config.fetch("vlan_vnis", {})
          nve = config.fetch("nve", {}).fetch("members", {})
          evpn = config.fetch("evpn", {})
          l3 = config.fetch("vrfs", {}).values.filter_map { |vrf| vrf["vni"] }
          l2 = evpn.filter_map { |vni, member| Integer(vni) if member["type"] == "l2" }
          l2.concat(nve.filter_map { |vni, member| Integer(vni) unless member["associate_vrf"] })
          l3.concat(nve.filter_map { |vni, member| Integer(vni) if member["associate_vrf"] })
          l3.concat(evpn.filter_map { |vni, member| Integer(vni) if member["type"] == "l3" })
          vnis = (mappings.values.compact - l3 + l2).uniq
          mappings_by_vni = mappings.group_by { |_vlan, vni| vni }
          vnis.sort.each do |vni|
            vlans = mappings_by_vni.fetch(vni, []).map(&:first)
            (vlans.empty? ? [ nil ] : vlans).each do |vlan|
              member, control = nve[vni.to_s], evpn[vni.to_s]
              missing = []
              missing << "VLAN" unless vlan
              missing << "NVE" unless member
              missing << "NVE L2" if member && member["associate_vrf"]
              missing << "EVPN" if config["nv_overlay_evpn"] && !control
              missing << "EVPN L2" if control && control["type"] != "l2"
              result[vni] << { host: host, config: config, vlan: vlan, svi: vlan && config.fetch("interfaces", {})["Vlan#{vlan}"],
                nve: member, evpn: control, missing: missing }
            end
          end
        end
        result
      end

      # 成员未指定复制方式时继承全局组播；显式 BGP/成员组播优先。
      def self.nve_member(config, member)
        return nil unless member
        inherited = config.dig("nve", "multicast_group")
        if inherited && !member["replication"] && !member["multicast_group"] && !member["associate_vrf"]
          member.merge("multicast_group" => inherited)
        else
          member
        end
      end

      # 两字节 AS 的 auto RT 为 AS:VNI；其他 AS 形式保留声明，不猜测版本相关派生行为。
      def self.route_targets(entries, asn:, vni:)
        Array(entries).flat_map do |entry|
          directions = entry["direction"] == "both" ? %w[import export] : [ entry["direction"] ]
          directions.map do |direction|
            target = entry["target"]
            target = asn.is_a?(Integer) && asn.between?(1, 65_535) ? "#{asn}:#{vni}" : [ "auto", asn, vni ] if target == "auto"
            [ entry["address_family"], entry.fetch("evpn", false), direction, target ]
          end
        end.uniq.sort_by { |entry| JSON.generate(entry) }
      end

      # 租户出口细节可以因 Border 职责不同而不同，此投影只比较 VNI 与导入导出声明。
      def self.tenant(config, name)
        vrf = config.fetch("vrfs", {})[name]
        return nil unless vrf
        { "vrf" => name, "vni" => vrf["vni"], "route_targets" => route_targets(vrf["route_targets"], asn: config.dig("bgp", "asn"), vni: vrf["vni"]) }
      end
    end
  end
end
