# frozen_string_literal: true

require_relative "bgp_neighbors"

module Vxlan
  # 关联命名列表、route-map 选择器及所有支持的路由使用方。
  class PrefixListReferences
    # 绑定路由配置，用于解析前缀列表的使用方。
    def initialize(configuration)
      @configuration = configuration
    end

    # 按地址族将前缀列表关联到 route-map 条目和路由使用方。
    def call(address_family: "ipv4")
      raise ArgumentError, "Unsupported address family" unless %w[ipv4 ipv6].include?(address_family)

      bindings = route_map_bindings.transform_values(&:uniq)
      references = @configuration.fetch(:route_maps).each_with_object({}) do |(name, entries), result|
        entries.sort_by { |entry| entry.fetch(:sequence) }.each do |entry|
          matches = entry.fetch(:prefix_list_matches) do
            [ { address_family: "ipv4", selector: "address", names: entry.fetch(:prefix_lists, []) } ]
          end
          matches.select { |match| match[:address_family] == address_family }.each do |match|
            route_map_reference = { type: "route_map", name: name, sequence: entry.fetch(:sequence), action: entry.fetch(:action),
              bindings: bindings.fetch(name, []).dup }
            route_map_reference[:selector] = match[:selector] unless match[:selector] == "address"
            match.fetch(:names).uniq.each do |prefix_list|
              (result[prefix_list] ||= []) << route_map_reference
            end
          end
        end
      end
      # 一次去重保留首次出现顺序，避免每个条目都扫描已有引用。
      references.transform_values(&:uniq)
    end

    private

    # 关联关系保留协议、VRF、地址族及对等体，避免共享策略被混用。
    def route_map_bindings
      result = Hash.new { |hash, key| hash[key] = [] }
      bgp = @configuration.fetch(:bgp)
      { "default" => bgp }.merge(bgp.fetch(:vrfs, {})).each do |vrf, settings|
        settings.fetch(:address_families, {}).each do |family, values|
          context = { protocol: "bgp", process: bgp[:asn].to_s, vrf: vrf, address_family: family }
          add_redistribution(result, values, context)
          values.fetch(:networks, []).each do |network|
            next unless network[:route_map]

            result[network[:route_map]] << context.merge(usage: "network", prefix: network.fetch(:prefix))
          end
          retain = values[:retain_route_target]
          if retain&.start_with?("route-map ")
            result[retain.delete_prefix("route-map ")] << context.merge(usage: "retain_route_target")
          end
        end
      end
      BgpNeighbors.new(bgp).each do |vrf, peer, settings|
        settings.fetch(:address_families, {}).each do |family, values|
          values.fetch(:route_maps, {}).each do |direction, route_map|
            result[route_map] << { protocol: "bgp", process: bgp[:asn].to_s, vrf: vrf,
              address_family: family, usage: "neighbor_route_map", peer: peer, direction: direction.to_s }
          end
        end
      end
      @configuration.fetch(:ospf).each do |process, settings|
        { "default" => settings }.merge(settings.fetch(:vrfs, {})).each do |vrf, values|
          add_redistribution(result, values, protocol: "ospf", process: process, vrf: vrf)
        end
      end
      @configuration.fetch(:vrfs, {}).each do |vrf, settings|
        settings.fetch(:exports, []).each do |entry|
          result[entry.fetch(:route_map)] << { protocol: "vrf", vrf: vrf, address_family: entry.fetch(:address_family),
            usage: "export", target_vrf: entry.fetch(:vrf) }
        end
      end
      result
    end

    # 将重分发 route-map 关联到其路由使用方。
    def add_redistribution(result, settings, context)
      settings.fetch(:redistribute, []).each do |entry|
        next unless entry[:route_map]

        result[entry[:route_map]] << context.merge(usage: "redistribute", source_protocol: entry.fetch(:protocol),
          source_process: entry[:process]).compact
      end
    end
  end
end
