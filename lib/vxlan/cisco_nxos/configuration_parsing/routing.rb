# frozen_string_literal: true

module Vxlan
  module CiscoNxos
    module ConfigurationParsing
      # 路由作用域保留邻居、模板、VRF 与地址族的归属。
      module Routing
        private

        # 解析支持的路由作用域及协议关系。
        def routing(block, protocol)
          values = { vrfs: {}, neighbors: {}, templates: {}, address_families: {}, redistribute: [] }
          analyze_children(block) do |child|
            case child.text
            when /\Avrf (\S+)\z/ then store(values[:vrfs], $1, child, path: @source_path + [ :vrfs, $1 ]) { routing(child, protocol) }
            when /\Atemplate peer (\S+)\z/ then store(values[:templates], $1, child, path: @source_path + [ :templates, $1 ]) { routing(child, protocol) }
            when /\Aneighbor (\S+)\z/ then store(values[:neighbors], $1, child, path: @source_path + [ :neighbors, $1 ]) { routing(child, protocol) }
            when /\Aaddress-family (.+)\z/ then store(values[:address_families], $1, child, path: @source_path + [ :address_families, $1 ]) { routing(child, protocol) }
            when /\Arouter-id (\S+)\z/ then values[:router_id] = address($1)
            when /\Aremote-as (\S+)\z/
              value = $1
              integer(value, 1..4_294_967_295) unless %w[internal external].include?(value)
              values[:remote_as] = value
            when /\Ainherit peer (\S+)\z/ then values[:inherit_peer] = $1
            when /\Aupdate-source (\S+)\z/ then values[:update_source] = $1
            when /\Adescription (.+)\z/ then values[:description] = $1
            when /\Aroute-map (\S+) (in|out)\z/
              name, direction = $1, $2.to_sym
              maps = (values[:route_maps] ||= {})
              raise ArgumentError if maps.key?(direction)

              maps[direction] = name
            when /\A(no )?next-hop-self( all)?\z/
              values[:next_hop_self], values[:next_hop_self_all] = $1.nil?, $1.nil? && !$2.nil?
            when /\A(no )?(bfd|route-reflector-client|advertise-pip|advertise l2vpn evpn)\z/
              enabled, setting = $1.nil?, $2
              key = { "bfd" => :bfd, "route-reflector-client" => :route_reflector_client,
                "advertise-pip" => :advertise_pip, "advertise l2vpn evpn" => :advertise_l2vpn_evpn }.fetch(setting)
              values[key] = enabled
            when /\A(no )?send-community(?: (extended|both))?\z/
              enabled, kind = $1.nil?, $2
              values[:standard_community] = enabled unless kind == "extended"
              values[:extended_community] = enabled if kind
            when /\Anetwork (\S+)(?: route-map (\S+))?\z/
              subnet, route_map = $1, $2
              raise ArgumentError unless protocol == :bgp

              (values[:networks] ||= []) << { prefix: network_prefix(subnet), route_map: route_map }.compact
            when /\Aredistribute (\S+)(?: (?!route-map\b)(\S+))?(?: route-map (\S+))?\z/
              values[:redistribute] << { protocol: $1, process: $2, route_map: $3 }.compact
            when /\Aretain route-target (all|route-map \S+)\z/ then values[:retain_route_target] = $1
            when /\A(?:no )?(?:log-neighbor-changes|log-adjacency-changes|soft-reconfiguration inbound|passive-interface)\b/,
              /\A(?:maximum-paths|default-information originate|auto-cost reference-bandwidth)\b/ then ignore(child)
            else issue(child)
            end
          end
          values
        end
      end
    end
  end
end
