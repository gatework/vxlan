# frozen_string_literal: true

require_relative "parser_registry"
require_relative "observation"

module Vxlan
  # 将纯平台解析事实封装为对应 VXLAN 维度观测。
  class RuntimeParser
    # 按请求的平台和型号选择运行解析行为。
    def initialize(platform: :cisco_nxos, model: nil)
      @profile = ParserRegistry.fetch(platform, model: model)
    end

    # 拒绝配置维度，仅解析所选 VXLAN 运行查询。
    def parse(name, text, complete: false)
      raise ArgumentError, "Unsupported runtime dimension" if name == :configuration || !@profile.commands.key?(name)

      result = @profile.parse(name, text, complete: complete)
      Observation.new(name: name, **result.to_h)
    end
  end
end
