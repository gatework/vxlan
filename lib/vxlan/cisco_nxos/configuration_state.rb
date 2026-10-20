# frozen_string_literal: true

require "ctx_parser/values"

module Vxlan
  module CiscoNxos
    # 归纳 NX-OS 模板引用、功能身份及 SVI、VLAN、VNI 子网关系。
    class ConfigurationState
      attr_reader :data, :issues

      # 初始化单次配置解析使用的可变 NX-OS 事实容器。
      def initialize
        @data = { hostname: nil, features: [], disabled_features: [], breakouts: {}, interfaces: {}, vlan_vnis: {}, vrfs: {}, nve: { members: {} },
          evpn: {}, bgp: {}, ospf: {}, vpc_domain: nil, unnumbered_addresses: {}, prefix_lists: {}, ipv6_prefix_lists: {}, route_maps: {}, acls: {}, address_groups: {}, static_routes: [] }
        @issues = []
      end

      # 解析结束后关联跨块引用，避免声明顺序影响结果。
      def finalize_facts
        peer_template_issues
        resolve_unnumbered_addresses
        issues << { code: :conflicting_feature_state } if (data[:features] & data[:disabled_features]).any?
        issues << { code: :hostname_missing } unless data[:hostname]
        data[:features] = data[:features].uniq.sort
        data[:disabled_features] = data[:disabled_features].uniq.sort
        data[:segments] = build_svi_segments
        data
      end

      # 展示对象身份与状态，避免泄露原始回显或凭据。
      def inspect = "#<#{self.class} interfaces=#{data[:interfaces].size} issues=#{issues.size}>"

      private

      # 借用的 IPv4 地址仅作为主机身份，不猜测链路网段。
      def resolve_unnumbered_addresses
        interfaces = data[:interfaces]
        by_name = interfaces.group_by { |name, _values| name.downcase }
        interfaces.each do |name, values|
          next unless values[:unnumbered_interface]

          sources = by_name.fetch(values[:unnumbered_interface].downcase, [])
          source = sources.one? ? sources.first.last : nil
          if source && source[:addresses].one? && values[:addresses].empty? &&
              !source[:unnumbered_interface] && source.fetch(:vrf, "default") == values.fetch(:vrf, "default")
            data[:unnumbered_addresses][name] = [ "#{source[:addresses].first.split('/').first}/32" ]
          else
            issues << { code: :unresolved_unnumbered_interface, interface: name }
          end
        end
      end

      # 报告未解析的继承模板，不虚构模板配置。
      def peer_template_issues
        bgp = data[:bgp]
        templates = bgp.fetch(:templates, {})
        issues << { code: :unsupported_peer_inheritance } if templates.values.any? { |settings| settings[:inherit_peer] }
        [ bgp, *bgp.fetch(:vrfs, {}).values ].each do |scope|
          scope.fetch(:neighbors, {}).each_value do |neighbor|
            next unless neighbor[:inherit_peer] && !templates.key?(neighbor[:inherit_peer])

            issues << { code: :missing_peer_template }
          end
        end
      end

      # 根据显式配置构建 VLAN 与 VNI 网段关联。
      def build_svi_segments
        data[:interfaces].filter_map do |name, values|
          match = /\AVlan(\d+)\z/.match(name)
          next unless match && data[:vlan_vnis][match[1].to_i] && values[:addresses].any?
          unless values[:addresses].one? && values[:vrf]
            issues << { code: :unsupported_svi, interface: name }
            next
          end
          source = values[:addresses].first
          { vlan_id: match[1].to_i, vni: data[:vlan_vnis].fetch(match[1].to_i), vrf: values[:vrf],
            prefix: CtxParser::Values.ipv4_prefix(source), gateway: source.split("/").first,
            anycast: values[:anycast], acl_bindings: values[:acl_bindings] }
        end
      end
    end
  end
end
