# frozen_string_literal: true

module Vxlan
  # 统一解析对等体模板，供清单投影与策略引用共用。
  class BgpNeighbors
    include Enumerable

    # 绑定需要解析对等体模板继承关系的 BGP 配置。
    def initialize(bgp)
      @bgp = bgp
    end

    # 合并受支持的对等体模板后，逐个返回配置邻居，不推断运行会话状态。
    def each
      return enum_for(:each) unless block_given?

      peer_templates = @bgp.fetch(:templates, {})
      { "default" => @bgp }.merge(@bgp.fetch(:vrfs, {})).each do |vrf, vrf_configuration|
        vrf_configuration.fetch(:neighbors, {}).each do |peer, neighbor_configuration|
          inherited_name = neighbor_configuration[:inherit_peer]
          # 未解析或已冲突的模板不能生成看似有效的邻居投影。
          next if inherited_name && !peer_templates.key?(inherited_name)

          peer_template = peer_templates.fetch(inherited_name, {})
          # 模板自身继承尚不受支持，不能把部分模板当作已解析配置。
          next if peer_template[:inherit_peer]

          address_families = peer_template.fetch(:address_families, {}).merge(neighbor_configuration.fetch(:address_families, {})) do |_name, template_family, neighbor_family|
            template_family.merge(neighbor_family.compact).merge(route_maps: template_family.fetch(:route_maps, {}).merge(neighbor_family.fetch(:route_maps, {})))
          end
          yield vrf, peer, peer_template.merge(neighbor_configuration.compact).merge(address_families: address_families)
        end
      end
    end
  end
end
