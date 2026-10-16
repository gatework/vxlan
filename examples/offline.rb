# frozen_string_literal: true

require "vxlan"

# 使用合成 NX-OS OSPF 回显；文档地址不作为实时目标。
output = <<~CLI
  OSPF Process ID UNDERLAY VRF default
  Total number of neighbors: 1
  Neighbor ID Pri State Up Time Address Interface
  192.0.2.2 1 FULL/ - 1d 192.0.2.3 Eth1/1
CLI
observation = Vxlan::RuntimeParser.new.parse(:ospf_neighbors, output, complete: true)
puts "OSPF parse status: #{observation.status}"
puts "Neighbors: #{observation.records.size}"
observation.records.each { |record| p record }
# 单个已解析邻居仅是一项观测，不能证明整个 Fabric 健康。
