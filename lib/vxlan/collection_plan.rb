# frozen_string_literal: true

require_relative "observation"

module Vxlan
  # 配置证据约束运行查询：明确未启用的功能才允许空回显或省略查询。
  class CollectionPlan
    def initialize(profile:, configuration: nil)
      @profile, @configuration = profile, configuration
    end

    def parse_many(names, body, complete:, command:)
      if names.one? && body.strip.empty? && unconfigured?(names.first)
        name = names.first
        code = name == :port_channels ? :port_channels_not_configured : :nve_not_configured
        return { name => CtxParser::Result.new(status: :complete, issues: [ { code: code } ]) }
      end
      @profile.parse_many(names, body, complete: complete, command: command)
    end

    # 仅当同一会话的完整配置证明功能未启用时，才接受空运行回显。
    def unconfigured?(name)
      return false unless @configuration&.complete? && @configuration.records.one?

      settings = @configuration.records.first
      case name
      when :vpc then !settings[:vpc_domain] && !settings.fetch(:features).include?("vpc")
      when :nve_peers, :nve_vnis then !settings.fetch(:nve)[:interface]
      when :port_channels
        settings.fetch(:interfaces).none? { |interface, values| /\Aport-channel\d+\z/i.match?(interface) || values[:channel_group] }
      else false
      end
    end
  end
end
