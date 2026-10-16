# frozen_string_literal: true

require_relative "../evpn_l2route"

module Vxlan
  module CiscoNxos
    module Parsers
      # 解析 show l2route evpn mac all 的 CLI 回显。
      class ShowL2routeEvpnMacAll < EvpnL2route
        TYPE = :mac
      end
    end
  end
end
