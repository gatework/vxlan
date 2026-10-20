# frozen_string_literal: true

module Vxlan
  module CiscoNxos
    module Syntax
      # 路由作用域保留邻居、模板、VRF 与地址族的归属。
      module Routing
        private

        # 解析支持的路由作用域及协议关系。
        def routing(block, protocol, context = :process, family: nil, parent: nil)
          values = { vrfs: {}, neighbors: {}, templates: {}, address_families: {}, redistribute: [] }
          neighbor_keys = {}
          analyze_children(block) do |child|
            next issue(child) unless routing_leaf?(child.text, protocol, context, family, parent)

            case child.text
            when /\Avrf (\S+)\z/ then routing_scope(values, :vrfs, $1, child, protocol, context)
            when /\Atemplate peer (\S+)\z/ then routing_scope(values, :templates, $1, child, protocol, context)
            when /\Aneighbor (\S+)\z/ then routing_scope(values, :neighbors, $1, child, protocol, context, neighbor_keys: neighbor_keys)
            when /\Aaddress-family (.+)\z/ then routing_scope(values, :address_families, $1, child, protocol, context)
            when /\Arouter-id (\S+)\z/
              router_id = ip_address($1)
              raise ArgumentError unless IPAddr.new(router_id).ipv4?

              assign(values, :router_id, router_id, child)
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
              unless protocol == :bgp && context == :address_families && %i[process vrfs].include?(parent) &&
                  /\Aipv[46] (?:unicast|multicast)\z/.match?(family)
                next issue(child)
              end

              (values[:networks] ||= []) << { prefix: network_prefix(subnet, family: family.split.first), route_map: route_map }.compact
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

        # 已建模叶子必须位于其使用方作用域，不能只因文字可解析就接受事实。
        def routing_leaf?(text, protocol, context, family, parent)
          process_family = context == :address_families && %i[process vrfs].include?(parent)
          case text
          when /\A(?:no )?(?:send-community|next-hop-self|route-reflector-client|advertise-pip|advertise l2vpn evpn)\b/
            protocol == :bgp && context == :address_families
          when /\A(?:remote-as|inherit peer|update-source)\b/
            protocol == :bgp && %i[neighbors templates].include?(context)
          when /\Aroute-map\b/
            protocol == :bgp && context == :address_families && %i[neighbors templates].include?(parent)
          when /\Aredistribute\b/
            if protocol == :ospf
              %i[process vrfs].include?(context)
            else
              process_family && /\Aipv[46] (?:unicast|multicast)\z/.match?(family)
            end
          when /\Aretain route-target\b/
            protocol == :bgp && process_family && family == "l2vpn evpn"
          when /\Arouter-id\b/
            %i[process vrfs].include?(context)
          else true
          end
        end

        # 只进入当前事实模型可表达的子作用域，阻止任意递归及跨协议误归属。
        def routing_scope(values, kind, name, block, protocol, context, neighbor_keys: nil)
          supported = case kind
          when :vrfs then context == :process
          when :templates then protocol == :bgp && context == :process
          when :neighbors then protocol == :bgp && %i[process vrfs].include?(context)
          when :address_families
            protocol == :bgp && %i[process vrfs neighbors templates].include?(context) &&
              /\A(?:ipv[46] (?:unicast|multicast)|vpnv[46] unicast|l2vpn evpn)\z/.match?(name)
          end
          return issue(block) unless supported

          # 邻居允许主机与动态前缀；坏身份只排除本块，保留同进程其他事实。
          if kind == :neighbors
            begin
              canonical = name.include?("/") ? network_prefix(name) : ip_address(name)
              # 身份索引用标准地址；事实键保留首次原文，重复项仍走统一的冲突与来源失效规则。
              name = neighbor_keys[canonical] ||= name
            rescue ArgumentError, IPAddr::Error
              return issue(block, :invalid_configuration_value)
            end
          end

          conflicts_before = @configuration_conflict_count
          store_unique_fact(values[kind], name, block, path: @source_path + [ kind, name ]) do
            routing(block, protocol, kind, family: kind == :address_families ? name : nil, parent: context)
          end
          # 邻居及模板的子地址族冲突也使继承身份失效；保留同进程其他邻居。
          if protocol == :bgp && %i[neighbors templates].include?(kind) && @configuration_conflict_count > conflicts_before
            exclude_conflicted_scope(values[kind], name, block)
          end
        end
      end
    end
  end
end
