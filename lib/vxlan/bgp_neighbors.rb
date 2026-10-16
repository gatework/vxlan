# frozen_string_literal: true

module Vxlan
  # 统一解析对等体模板，供清单投影与策略引用共用。
  class BgpNeighbors
    include Enumerable

    # 绑定需要解析对等体模板继承关系的 BGP 配置。
    def initialize(bgp)
      @bgp = bgp
    end

    # 应用继承的对等体模板配置后，逐个返回实际生效的 BGP 邻居。
    def each
      return enum_for(:each) unless block_given?

      templates = @bgp.fetch(:templates, {})
      { "default" => @bgp }.merge(@bgp.fetch(:vrfs, {})).each do |vrf, scope|
        scope.fetch(:neighbors, {}).each do |peer, child|
          parent = templates.fetch(child[:inherit_peer], {})
          families = parent.fetch(:address_families, {}).merge(child.fetch(:address_families, {})) do |_name, inherited, explicit|
            inherited.merge(explicit.compact).merge(route_maps: inherited.fetch(:route_maps, {}).merge(explicit.fetch(:route_maps, {})))
          end
          yield vrf, peer, parent.merge(child.compact).merge(address_families: families)
        end
      end
    end
  end
end
