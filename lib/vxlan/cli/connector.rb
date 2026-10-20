# frozen_string_literal: true

module Vxlan
  module CLI
    # 可选传输适配器；只由联网采集使用，解析库不引用 net-connector。
    class Connector
      # 固定设备与接入选项，不在构造时建立会话。
      def initialize(device, settings)
        @device, @settings = device, settings
      end

      # 向 Collector 声明已知平台，不把品牌猜测当作型号识别。
      def platform = :cisco_nxos

      # 连接器拥有原生会话；CtxDriver 仅借用，不负责关闭或重连。
      def open
        Net::Connector.open(:cisco_nxos, host: @device.fetch("host"), **@settings) do |native|
          native.with_operation(:vxlan) { yield native }
        end
      end
    end
  end
end
