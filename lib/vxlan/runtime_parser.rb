# frozen_string_literal: true

require_relative "parser_registry"
require_relative "observation"

module Vxlan
  # 将纯平台解析事实封装为对应 VXLAN 维度观测。
  class RuntimeParser
    # 按请求的平台和型号选择运行解析行为。
    def initialize(platform:, model: nil)
      @profile = ParserRegistry.fetch(platform, model: model)
    end

    # 拒绝配置维度，仅解析所选 VXLAN 运行查询。
    def parse(name, text, complete: false, command: nil)
      parse_many([ name ], text, complete: complete, command: command).fetch(name)
    end

    # 单条正文只允许投影属于同一声明命令的运行维度。
    def parse_many(names, text, complete: false, command: nil)
      unless names.is_a?(Array) && names.any? && names.uniq == names &&
          names.all? { |name| name.is_a?(Symbol) && name != :configuration && @profile.commands.key?(name) }
        raise ArgumentError, "Unsupported runtime dimensions"
      end
      @profile.parse_many(names, text, complete: complete, command: command).to_h do |name, result|
        [ name, Observation.new(name: name, **result.to_h) ]
      end
    end
  end
end
