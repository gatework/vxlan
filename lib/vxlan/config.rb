# frozen_string_literal: true

require_relative "parser_registry"
require_relative "observation"

module Vxlan
  # 配置与运行观测使用相同的平台、型号策略。
  class Config
    # 按当前平台和型号选择 VXLAN 配置策略。
    def initialize(platform: :cisco_nxos, model: nil)
      @profile = ParserRegistry.fetch(platform, model: model)
    end

    # 解析 NX-OS 配置，将事实封装为 VXLAN 配置观测。
    def parse(text, complete: false)
      result = @profile.parse(:configuration, text, complete: complete)
      Observation.new(name: :configuration, **result.to_h)
    end
  end
end
