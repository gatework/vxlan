# frozen_string_literal: true

require_relative "parser_registry"
require "ctx_driver"
require_relative "observation"
require_relative "snapshot"

module Vxlan
  # 单设备单会话顺序采集；各维度独立失败，断链后不重放查询。
  class Collector
    COMMANDS = CiscoNxos::Profile::COMMANDS
    PREPARATION_COMMANDS = [ "terminal length 0", "terminal width 511" ].freeze

    # 注入为顺序命令观测生成时间戳的时钟。
    def initialize(clock: -> { Time.now.utc })
      @clock = clock
    end

    # 通过调用方持有的连接器顺序采集请求维度。
    def collect(connector:, target:, fabric_key:, model: nil, dimensions: COMMANDS.keys)
      raise ArgumentError, "Target must be a hash" unless target.is_a?(Hash)

      unless dimensions.is_a?(Array) && dimensions.any? && dimensions.uniq == dimensions && (dimensions - COMMANDS.keys).empty?
        raise ArgumentError, "Unknown or duplicate VXLAN dimensions"
      end
      target = CtxParser::Immutable.copy(target)
      fabric_key = CtxParser::Immutable.copy(fabric_key)
      dimensions = dimensions.dup.freeze
      raise ArgumentError, "VXLAN requires Cisco NX-OS" unless connector.platform.to_s == "cisco_nxos"
      profile = ParserRegistry.fetch(connector.platform, model: model)

      observations = {}
      session_finished = false
      begin
        connector.open do |session|
          reader = CtxDriver::Reader.new(session: session, clock: @clock)
          if (code = prepare(reader))
            dimensions.each { |name| observations[name] = failure(name, code) }
            observations[:collection] = failure(:collection, code)
            next
          end
          dimensions.each do |name|
            config = observations[:configuration]
            if name == :vpc && !reader.failure && unconfigured?(name, config)
              observations[name] = Observation.new(name: name, status: :complete, completed_at: @clock.call,
                issues: [ { code: :vpc_not_configured } ])
            else
              observations[name] = read(reader, name, config, profile)
            end
          end
          session_finished = true
        end
      rescue StandardError => error
        raise unless CtxDriver::Failure.connection_error?(error, connector)

        code = CtxDriver::Failure.code(error, :connection_failed)
        dimensions.each { |name| observations[name] ||= failure(name, code) }
        observations[:collection] = failure(:collection, session_finished ? :session_close_failed : code)
      end
      status = if observations.values.all?(&:complete?)
        :complete
      elsif observations.values.any? { |value| %i[complete partial].include?(value.status) }
        :partial
      else
        :failed
      end
      observations[:collection] ||= Observation.new(name: :collection, status: status, completed_at: @clock.call)
      Snapshot.new(target: target,
        fabric_key: fabric_key, dimensions: observations, observed_at: @clock.call)
    end

    private

    # 采集设备回显前，禁用分页并归一化终端宽度。
    def prepare(reader)
      PREPARATION_COMMANDS.each do |command|
        capture = reader.read(command)
        return capture.failure.fetch(:code) unless capture.success?
      end
      nil
    end

    # 解析失败限定在单条查询内；Reader 负责传输与回执校验。
    def read(reader, name, configuration, profile)
      command = profile.command(name)
      capture = reader.read(command)
      metadata = { started_at: capture.started_at, completed_at: capture.completed_at, evidence: capture.evidence }
      unless capture.success?
        return failed_capture(name, capture, command).with(**metadata)
      end
      begin
        body = capture.body
        parsed = if body.strip.empty? && unconfigured?(name, configuration)
          code = name == :port_channels ? :port_channels_not_configured : :nve_not_configured
          Observation.new(name: name, status: :complete, issues: [ { code: code } ])
        else
          Observation.new(name: name, **profile.parse(name, body, complete: true).to_h)
        end
        parsed.with(**metadata)
      rescue StandardError => error
        details = CtxDriver::Failure.details(error, fallback: :command_processing_failed, stage: :parse)
        failure(name, details.fetch(:code), **details.except(:code), command: command).with(**metadata)
      end
    end

    # 保留传输首次不可用原因，并标记从未发送的命令。
    def failed_capture(name, capture, command)
      failure(name, capture.failure.fetch(:code), **capture.failure.except(:code), command: command, skipped: capture.skipped?)
    end

    # 仅当同一会话的完整配置证明功能未启用时，才接受空运行回显。
    def unconfigured?(name, configuration)
      return false unless configuration&.complete? && configuration.records.one?

      settings = configuration.records.first
      case name
      when :vpc then !settings[:vpc_domain] && !settings.fetch(:features).include?("vpc")
      when :nve_peers, :nve_vnis then !settings.fetch(:nve)[:interface]
      when :port_channels
        settings.fetch(:interfaces).none? { |interface, values| /\Aport-channel\d+\z/i.match?(interface) || values[:channel_group] }
      else false
      end
    end

    # 构建失败观测，不丢弃已成功的同级维度。
    def failure(name, code, **details)
      Observation.new(name: name, status: :failed, issues: [ { code: code, **details } ], completed_at: @clock.call)
    end
  end
end
