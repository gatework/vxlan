# frozen_string_literal: true

require_relative "../change_plan"
require_relative "../acl_policy"
require_relative "catalog"

module Vxlan
  module Service
    # 由完整同业务对端证明关联关系，而不是通过 VNI 数字编码猜测 VLAN。
    class Mapping
      # 只接受同 Fabric、同角色业务行，返回已校验的业务增量对象或未知。
      def self.infer(vni, row, peers)
        return nil unless peers.map { |peer| peer[:host] }.uniq.size == peers.size
        donors = peers.reject { |peer| peer[:host] == row[:host] }
        return nil unless donors.any? && donors.all? { |peer| peer[:missing].empty? && peer[:svi] }
        signatures = donors.map { |peer| signature(peer[:config], peer[:svi]) }.uniq
        return nil unless signatures.one? && signatures.first
        expected = signatures.first
        return nil unless transport_matches?(vni, row, donors)
        matches = row[:config].fetch("vlan_vnis", {}).filter_map do |vlan, mapped|
          next unless mapped.nil?
          svi = row[:config].fetch("interfaces", {})["Vlan#{vlan}"]
          vlan if svi && signature(row[:config], svi) == expected
        end
        return nil unless matches.one?
        change = { "kind" => "vlan_vni_add", "vlan" => Integer(matches.first), "vni" => vni, "vrf" => expected["vrf"], "address" => expected["addresses"].first }
        ChangePlan.candidate(change, config: row[:config])
      end

      # 网关、租户、ACL 及其依赖一起界定业务；缺失 Anycast 身份不能当成一致。
      def self.signature(config, svi)
        return nil unless svi["anycast"] && svi["vrf"] && svi.fetch("addresses", []).one? && config["anycast_mac"]
        policies = svi.fetch("acl_bindings", {}).to_h do |direction, name|
          policy = AclPolicy.resolve(config, config.fetch("acls", {})[name])
          return nil unless policy
          [ direction, policy.to_h ]
        end
        svi.slice("addresses", "vrf", "anycast", "shutdown", "mtu").merge("anycast_mac" => config["anycast_mac"], "policies" => policies)
      end

      # 本机已有 NVE/EVPN 与对端语义一致才允许连接 VLAN；路由冲突不能靠补绑定解决。
      def self.transport_matches?(vni, row, donors)
        values = [ row, *donors ].map do |peer|
          next nil unless peer[:nve] && peer[:evpn]
          config = peer[:config]
          vrf = peer[:svi]&.dig("vrf") || donors.first[:svi]["vrf"]
          [ Catalog.nve_member(config, peer[:nve]), peer[:evpn]["type"], Catalog.route_targets(peer[:evpn]["route_targets"], asn: config.dig("bgp", "asn"), vni: vni), Catalog.tenant(config, vrf) ]
        end
        values.none?(&:nil?) && values.uniq.one?
      end
    end
  end
end
