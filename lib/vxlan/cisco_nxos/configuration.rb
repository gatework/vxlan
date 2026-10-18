# frozen_string_literal: true

require_relative "configuration_state"

module Vxlan
  module CiscoNxos
    # 兼容既有加载路径；配置解析状态由 ConfigurationState 表达。
    Configuration = ConfigurationState
  end
end
