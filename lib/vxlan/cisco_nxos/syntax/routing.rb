# frozen_string_literal: true

module Vxlan
  module CiscoNxos
    module Syntax
      # 路由作用域保留邻居、模板、VRF 与地址族的归属。
      module Routing
        private

        # 解析支持的路由作用域及协议关系。
        def routing(block, protocol, context = :process)
          values = { vrfs: {}, neighbors: {}, templates: {}, address_families: {}, redistribute: [] }
          analyze_children(block) do |child|
            case child.text
            when /\Avrf (\S+)\z/ then routing_scope(values, :vrfs, $1, child, protocol, context)
            when /\Atemplate peer (\S+)\z/ then routing_scope(values, :templates, $1, child, protocol, context)
            when /\Aneighbor (\S+)\z/ then routing_scope(values, :neighbors, $1, child, protocol, context)
            when /\Aaddress-family (.+)\z/ then routing_scope(values, :address_families, $1, child, protocol, context)
            when /\Arouter-id (\S+)\z/ then assign(values, :router_id, address($1), child)
            when /\Aremote-as (\S+)\z/
              value = $1
              integer(value, 1..4_294_967_295) unless %w[internal external].include?(value)
              assign(values, :remote_as, value, child)
            when /\Ainherit peer (\S+)\z/ then assign(values, :inherit_peer, $1, child)
            when /\Aupdate-source (\S+)\z/ then assign(values, :update_source, $1, child)
            when /\Adescription (.+)\z/ then assign(values, :description, $1, child)
            when /\Aroute-map (\S+) (in|out)\z/
              name, direction = $1, $2.to_sym
              maps = (values[:route_maps] ||= {})
              assign(maps, direction, name, child)
            when /\A(no )?next-hop-self( all)?\z/
              assign(values, :next_hop_self, $1.nil?, child)
              assign(values, :next_hop_self_all, $1.nil? && !$2.nil?, child)
            when /\A(no )?(bfd|route-reflector-client|advertise-pip|advertise l2vpn evpn)\z/
              enabled, setting = $1.nil?, $2
              key = { "bfd" => :bfd, "route-reflector-client" => :route_reflector_client,
                "advertise-pip" => :advertise_pip, "advertise l2vpn evpn" => :advertise_l2vpn_evpn }.fetch(setting)
              assign(values, key, enabled, child)
            when /\A(no )?send-community(?: (extended|both))?\z/
              enabled, kind = $1.nil?, $2
              assign(values, :standard_community, enabled, child) unless kind == "extended"
              assign(values, :extended_community, enabled, child) if kind
            when /\Anetwork (\S+)(?: route-map (\S+))?\z/
              subnet, route_map = $1, $2
              raise ArgumentError unless protocol == :bgp

              (values[:networks] ||= []) << { prefix: network_prefix(subnet), route_map: route_map }.compact
            when /\Aredistribute (\S+)(?: (?!route-map\b)(\S+))?(?: route-map (\S+))?\z/
              values[:redistribute] << { protocol: $1, process: $2, route_map: $3 }.compact
            when /\Aretain route-target (all|route-map \S+)\z/ then assign(values, :retain_route_target, $1, child)
            when /\A(?:no )?(?:log-neighbor-changes|log-adjacency-changes|soft-reconfiguration inbound|passive-interface)\b/,
              /\A(?:maximum-paths|default-information originate|auto-cost reference-bandwidth)\b/ then ignore(child)
            else issue(child)
            end
          end
          values
        end

        # 只进入当前事实模型可表达的子作用域，阻止任意递归及跨协议误归属。
        def routing_scope(values, kind, name, block, protocol, context)
          supported = case kind
          when :vrfs then context == :process
          when :templates then protocol == :bgp && context == :process
          when :neighbors then protocol == :bgp && %i[process vrfs].include?(context)
          when :address_families then protocol == :bgp && %i[process vrfs neighbors templates].include?(context)
          end
          return issue(block) unless supported

          conflicts_before = @configuration_conflict_count
          store(values[kind], name, block, path: @source_path + [ kind, name ]) { routing(block, protocol, kind) }
          # 邻居及模板的子地址族冲突也使继承身份失效；保留同进程其他邻居。
          if protocol == :bgp && %i[neighbors templates].include?(kind) && @configuration_conflict_count > conflicts_before
            exclude_conflicted_scope(values[kind], name, block)
          end
        end
      end
    end
  end
end
