# frozen_string_literal: true

require "ctx_parser/profile"
require_relative "parsers/show_running_config"
require_relative "parsers/show_cdp_neighbors_detail"
require_relative "parsers/show_nve_peers"
require_relative "parsers/show_nve_vni"
require_relative "parsers/show_bgp_l2vpn_evpn_summary"
require_relative "parsers/show_ip_ospf_neighbors"
require_relative "parsers/show_vpc_brief"
require_relative "parsers/show_interface_brief"
require_relative "parsers/show_port_channel_summary"
require_relative "parsers/show_mac_address_table"
require_relative "parsers/show_l2route_evpn_mac_all"
require_relative "parsers/show_l2route_evpn_mac_ip_all"

module Vxlan
  module CiscoNxos
    # 声明 Cisco N9K NX-OS 命令，并通过 MODEL_PARSERS 逐命令覆盖型号差异。
    class Profile < CtxParser::Profile
      DECLARATIONS = CtxParser::Commands.new([
        { dimensions: [ :configuration ], command: "show running-config", parser: Parsers::ShowRunningConfig },
        { dimensions: [ :cdp_neighbors ], command: "show cdp neighbors detail", parser: Parsers::ShowCdpNeighborsDetail },
        { dimensions: [ :nve_peers ], command: "show nve peers", parser: Parsers::ShowNvePeers },
        { dimensions: [ :nve_vnis ], command: "show nve vni", parser: Parsers::ShowNveVni },
        { dimensions: [ :bgp_neighbors ], command: "show bgp l2vpn evpn summary", parser: Parsers::ShowBgpL2vpnEvpnSummary },
        { dimensions: [ :ospf_neighbors ], command: "show ip ospf neighbors", parser: Parsers::ShowIpOspfNeighbors },
        { dimensions: [ :vpc ], command: "show vpc brief", parser: Parsers::ShowVpcBrief },
        { dimensions: [ :interfaces ], command: "show interface brief", parser: Parsers::ShowInterfaceBrief },
        { dimensions: [ :port_channels ], command: "show port-channel summary", parser: Parsers::ShowPortChannelSummary },
        { dimensions: [ :mac_addresses ], command: "show mac address-table", parser: Parsers::ShowMacAddressTable },
        { dimensions: [ :l2route_macs ], command: "show l2route evpn mac all", parser: Parsers::ShowL2routeEvpnMacAll },
        { dimensions: [ :l2route_mac_ips ], command: "show l2route evpn mac-ip all", parser: Parsers::ShowL2routeEvpnMacIpAll }
      ])
    end
  end
end
