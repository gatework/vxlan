# frozen_string_literal: true

require_relative "spec_helper"
require "open3"
require "rbconfig"
require "json"

RSpec.describe "Standalone vxlan command parsers" do
  [ %w[configuration configuration_state], %w[configuration_state configuration] ].each do |paths|
    it "preserves configuration state loading and finalization through #{paths.join(' then ')}" do
      script = <<~RUBY
        ARGV.each { |path| require "vxlan/cisco_nxos/\#{path}" }
        abort "Configuration alias mismatch" unless Vxlan::CiscoNxos::Configuration.equal?(Vxlan::CiscoNxos::ConfigurationState)
        state = Vxlan::CiscoNxos::Configuration.new
        state.data[:hostname] = "LEAF"
        facts = state.finish
        abort "Unexpected finalization" unless facts.equal?(state.data) && facts[:hostname] == "LEAF" && facts[:segments] == [] && state.issues.empty?
        canonical = Vxlan::CiscoNxos::ConfigurationState.new
        canonical.data[:hostname] = "LEAF"
        abort "Finalization alias mismatch" unless canonical.finalize_facts == facts && canonical.issues.empty?
      RUBY
      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-rbundler/setup",
        "-I", File.expand_path("../lib", __dir__), "-e", script, *paths)

      expect(status).to be_success, stderr
    end
  end

  parsers = {
    "show_ip_ospf_neighbors" => [ "ShowIpOspfNeighbors", "Total number of neighbors: 0\n" ],
    "show_bgp_l2vpn_evpn_summary" => [ "ShowBgpL2vpnEvpnSummary", "No BGP neighbors found\n" ],
    "show_nve_peers" => [ "ShowNvePeers", "No peers found\n" ],
    "show_nve_vni" => [ "ShowNveVni", "No VNIs found\n" ],
    "show_port_channel_summary" => [ "ShowPortChannelSummary", "Number of port-channels: 0\n" ],
    "show_mac_address_table" => [ "ShowMacAddressTable", "No entries found\n" ],
    "show_interface_brief" => [ "ShowInterfaceBrief", "0 interfaces\n" ],
    "show_cdp_neighbors_detail" => [ "ShowCdpNeighborsDetail", "Total cdp entries displayed : 0\n" ],
    "show_l2route_evpn_mac_all" => [ "ShowL2routeEvpnMacAll", "No routes found\n" ],
    "show_l2route_evpn_mac_ip_all" => [ "ShowL2routeEvpnMacIpAll", "Total number of routes: 0\n" ],
    "show_running_config" => [ "ShowRunningConfig", "hostname LEAF-01\n" ],
    "show_vpc_brief" => [ "ShowVpcBrief", "vPC domain id : 7\nPeer status : peer adjacency formed ok\nvPC keep-alive status : peer is alive\nConfiguration consistency status : success\n" ]
  }

    parsers.each do |file, (constant, output)|
      it "loads and parses #{file} without Rails, a collector or a database" do
        script = <<~RUBY
          require "json"
          abort "Unexpected application dependency" if defined?(Rails) || defined?(ActiveRecord) || defined?(ActiveSupport) || defined?(Motor)
          parser = Object.const_get(ARGV.fetch(0))
          result = parser.parse(STDIN.read, complete: true)
          puts JSON.generate(status: result.status, issues: result.issues)
        RUBY
        stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-rbundler/setup",
          "-I", File.expand_path("../lib", __dir__),
          "-r", "vxlan/cisco_nxos/parsers/#{file}", "-e", script, "Vxlan::CiscoNxos::Parsers::#{constant}", stdin_data: output)

        expect(status).to be_success, stderr
        expect(JSON.parse(stdout)).to include("status" => "complete", "issues" => [])
      end
    end
end
