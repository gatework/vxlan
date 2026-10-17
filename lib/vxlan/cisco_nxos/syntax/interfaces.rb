# frozen_string_literal: true

module Vxlan
  module CiscoNxos
    module Syntax
      # 接口与 NVE 语法共用命令解析器的来源边界。
      module Interfaces
        private

        # 解析接口块及其显式配置属性。
        def interface(block)
          values = { addresses: [], acl_bindings: {}, anycast: false }
          analyze_children(block) do |child|
            case child.text
            when /\Aip address (\S+)(?: secondary)?\z/ then values[:addresses] << prefix($1, preserve_host_bits: true)
            when /\Aip unnumbered (loopback\d+)\z/i then assign(values, :unnumbered_interface, $1, child)
            when /\Avrf member (\S+)\z/ then assign(values, :vrf, $1, child)
            when /\Aip router ospf (\S+) area (\S+)\z/ then assign(values, :ospf, "#{$1} area #{$2}", child)
            when /\Aip ospf network (point-to-point|broadcast)\z/ then assign(values, :ospf_network_type, $1, child)
            when /\Amtu (\d+)\z/ then assign(values, :mtu, integer($1, 1..65_535), child)
            when /\Aswitchport mode (access|trunk|dot1q-tunnel|fex-fabric)\z/ then assign(values, :switchport_mode, $1, child)
            when /\Aswitchport access vlan (\d+)\z/ then assign(values, :access_vlan, integer($1, 1..4094), child)
            when "switchport", "no switchport" then assign(values, :switchport, child.text == "switchport", child)
            when "ip forward", "no ip forward" then assign(values, :ip_forward, child.text == "ip forward", child)
            when "fabric forwarding mode anycast-gateway" then values[:anycast] = true
            when /\Aip access-group (\S+) (in|out)\z/ then assign(values[:acl_bindings], $2.to_sym, $1, child)
            when /\Avpc (\d+)\z/ then assign(values, :vpc_id, integer($1, 1..4096), child)
            when "vpc peer-link" then values[:peer_link] = true
            when /\Achannel-group (\d+)(?: mode \S+)?\z/ then assign(values, :channel_group, integer($1, 1..4096), child)
            when /\Adescription (.+)\z/ then assign(values, :description, $1, child)
            when "shutdown" then assign(values, :shutdown, true, child)
            when "no shutdown" then assign(values, :shutdown, false, child)
            else check_unhandled(child)
            end
          end
          values
        end

        # 解析 NVE 接口设置与成员 VNI 声明。
        def nve(block)
          values = { members: {} }
          analyze_children(block) do |child|
            case child.text
            when /\Amember vni (\d+)(?: (associate-vrf)| mcast-group (\S+))?\z/
              id, associated, group = integer($1, 1..16_777_215), !$2.nil?, $3
              member = { associate_vrf: associated }
              member[:multicast_group] = multicast_address(group) if group
              analyze_children(child) { |setting| nve_member(setting, member) }
              raise ArgumentError if member[:replication] == "bgp" && member[:multicast_group]

              store(values[:members], id, child, path: @source_path + [ :members, id ]) { member }
            when /\Adescription (.+)\z/ then assign(values, :description, $1, child)
            when /\Aglobal mcast-group (\S+)\z/ then assign(values, :multicast_group, multicast_address($1), child)
            when /\Asource-interface (\S+)\z/ then assign(values, :source_interface, $1, child)
            when /\Ahost-reachability protocol (\S+)\z/ then assign(values, :host_reachability, $1, child)
            when "shutdown" then assign(values, :shutdown, true, child)
            when "no shutdown" then assign(values, :shutdown, false, child)
            when "advertise virtual-rmac", "no advertise virtual-rmac"
              assign(values, :advertise_virtual_rmac, child.text == "advertise virtual-rmac", child)
            else issue(child)
            end
          end
          values
        end

        # 解析单个 NVE 成员 VNI 及其复制方式或 VRF 属性。
        def nve_member(setting, member)
          case setting.text
          when "ingress-replication protocol bgp" then member[:replication] = "bgp"
          when /\Amcast-group (\S+)\z/
            group = multicast_address($1)
            raise ArgumentError if member[:multicast_group] && member[:multicast_group] != group

            member[:multicast_group] = group
          when "suppress-arp" then assign(member, :suppress_arp, true, setting)
          when "no suppress-arp" then assign(member, :suppress_arp, false, setting)
          else issue(setting)
          end
        end

        # 校验 VXLAN 复制使用的组播地址。
        def multicast_address(value)
          group = address(value)
          raise ArgumentError unless IPAddr.new("224.0.0.0/4").include?(group)

          group
        end
      end
    end
  end
end
