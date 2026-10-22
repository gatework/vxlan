# frozen_string_literal: true

require_relative "spec_helper"
require "open3"

RSpec.describe "Host record separators" do
  it "parses runtime records independently of host input and output separators" do
    script = <<~'SCRIPT'
      require "vxlan"
      samples = {
        nve_peers: "Interface Peer-IP State LearnType Uptime Router-Mac\nnve1 192.0.2.2 Up CP 1d 0011.2233.4455\n",
        bgp_neighbors: "BGP summary information for VRF default, address family L2VPN EVPN\nNeighbor V AS MsgRcvd MsgSent TblVer InQ OutQ Up/Down State/PfxRcd\n192.0.2.2 4 65002 1 1 1 0 0 1d 5\n",
        vpc: "vPC domain id : 7\nPeer status : peer adjacency formed ok\nvPC keep-alive status : peer is alive\nConfiguration consistency status : success\nid Port Status Active vlans\n1 Po100 up 110,  120\n",
        l2route_macs: "Topology Mac Address Prod Next-Hops\n100 0011.2233.4455 BGP 192.0.2.2\n"
      }
      parser = Vxlan::RuntimeParser.new
      expected = samples.transform_values.with_index do |text, index|
        observation = parser.parse(samples.keys[index], text, complete: true)
        raise "Missing baseline records" unless observation.complete? && observation.records.one?
        observation.to_h
      end
      [ [ "\n", "HOST" ], [ nil, nil ], [ "!", nil ], [ "", "HOST" ] ].each do |input, output|
        # 宿主进程全局变量只在子进程内改变，避免污染其他测试。
        $/ = input
        $, = output
        $; = ","
        samples.each do |name, text|
          raise "Changed #{name}" unless parser.parse(name, text, complete: true).to_h == expected.fetch(name)
        end
        invalid = parser.parse(:nve_peers, "--More--\n", complete: true)
        raise "Lost terminal rejection" unless invalid.status == :partial && invalid.records.empty?
      end
    SCRIPT
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-rbundler/setup", "-I", File.expand_path("../lib", __dir__), "-e", script)
    expect(status.success?).to be(true), stderr
  end
end
