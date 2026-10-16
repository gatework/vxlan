# frozen_string_literal: true

require_relative "runtime_parser"

module Vxlan
  # 保留 L2RIB 公共入口，由平台策略选择解析实现。
  class L2routeParser
    TYPES = { l2route_macs: :mac, l2route_mac_ips: :mac_ip }.freeze

    # 选择 EVPN 路由维度使用的运行解析器。
    def initialize(platform: :cisco_nxos, model: nil)
      @parser = RuntimeParser.new(platform: platform, model: model)
    end

    # 校验 L2RIB 维度，将 EVPN 路由解析委派给平台策略。
    def parse(name, text, complete:)
      TYPES.fetch(name)
      @parser.parse(name, text, complete: complete)
    end
  end
end
