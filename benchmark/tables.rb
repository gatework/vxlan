# frozen_string_literal: true

require "vxlan"
require "json"

# 合成输入仅测本地关联和解析开销；同时核对状态及记录数量。
def measure(expected:)
  samples = 3.times.map do
    GC.start
    allocations = GC.stat(:total_allocated_objects)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    value = yield
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    allocated = GC.stat(:total_allocated_objects) - allocations
    raise "Unexpected benchmark result: #{value.inspect}" unless value == expected

    { milliseconds: (elapsed * 1000).round(3), allocations: allocated }
  end
  samples.min_by { |sample| sample[:milliseconds] }
end

[ 500, 2000, 5000 ].each do |count|
  peers = (1..count).map { |index| "10.#{index / 65_536}.#{index / 256 % 256}.#{index % 256}" }
  bgp = +"BGP summary information for VRF default, address family L2VPN EVPN\n"
  bgp << "Neighbor V AS MsgRcvd MsgSent TblVer InQ OutQ Up/Down State/PfxRcd\n"
  bgp << peers.map { |peer| "#{peer} 4 65001 0 0 0 0 0 1d 1\n" }.join
  bgp << "Neighbor T AS PfxRcd Type-2 Type-3 Type-4 Type-5\n"
  bgp << peers.map { |peer| "#{peer} I 65001 1 1 0 0 0\n" }.join
  parser = Vxlan::RuntimeParser.new
  stats = measure(expected: [ :complete, count ]) do
    result = parser.parse(:bgp_neighbors, bgp, complete: true)
    [ result.status, result.records.size ]
  end
  puts JSON.generate(case: "bgp_statistics", count: count, **stats)

  entries = (1..count).map { |sequence| { sequence: sequence, action: "permit", prefix_lists: [ "P" ] } }
  configuration = { bgp: {}, ospf: {}, route_maps: { "POLICY" => entries } }
  stats = measure(expected: count) { Vxlan::PrefixListReferences.new(configuration).call.fetch("P").size }
  puts JSON.generate(case: "prefix_references", count: count, **stats)

  l2route = +"Topology Mac Address Prod Next Hop (s)\n8 0011.2233.4455 BGP #{peers.first}\n"
  l2route << peers.drop(1).map { |peer| "  #{peer}\n" }.join
  stats = measure(expected: [ :complete, count ]) do
    result = parser.parse(:l2route_macs, l2route, complete: true)
    [ result.status, result.records.first.fetch(:next_hops).size ]
  end
  puts JSON.generate(case: "l2route_continuations", count: count, **stats)
end
