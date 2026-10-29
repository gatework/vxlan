# frozen_string_literal: true

require_relative "parser_registry"
require "ctx_driver"
require "ctx_runner/collection"
require "ctx_runner/query"
require_relative "collection_plan"
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
      target = CtxRunner::Target.snapshot(target)
      target, fabric_key, dimensions, profile = request(target, fabric_key, dimensions, connector.platform, model)

      observations = {}
      collection = CtxRunner::Collection.new
      collection.open(connector) { |session| observations.merge!(read_dimensions(session, dimensions, profile)) }
      if collection.failure
        code = collection.failure.fetch(:code)
        dimensions.each { |name| observations[name] ||= failure(name, code) }
      end
      snapshot(target, fabric_key, observations, issues: collection.failure ? [ collection.failure ] : [])
    end

    # 借用已打开的会话；调用方负责连接和关闭，本方法不重连、不提权。
    def collect_session(session:, target:, fabric_key:, platform: :cisco_nxos, model: nil, dimensions: COMMANDS.keys)
      target, fabric_key, dimensions, profile = request(target, fabric_key, dimensions, platform, model)
      snapshot(target, fabric_key, read_dimensions(session, dimensions, profile))
    end

    private

    # 连接前固定请求数据，生命周期入口和借用会话入口共用相同校验。
    def request(target, fabric_key, dimensions, platform, model)
      target = CtxRunner::Target.snapshot(target)
      unless fabric_key.is_a?(String) && !fabric_key.strip.empty? && !/[\x00-\x1f\x7f]/.match?(fabric_key)
        raise ArgumentError, "Fabric identity must be nonempty text"
      end
      unless dimensions.is_a?(Array) && dimensions.any? && dimensions.uniq == dimensions && (dimensions - COMMANDS.keys).empty?
        raise ArgumentError, "Unknown or duplicate VXLAN dimensions"
      end
      raise ArgumentError, "VXLAN requires Cisco NX-OS" unless platform.to_s == "cisco_nxos"

      [ CtxParser::Immutable.copy(target), CtxParser::Immutable.copy(fabric_key), dimensions.dup.freeze,
        ParserRegistry.fetch(platform, model: model) ]
    end

    # 配置先于依赖它的运行查询读取；结果维度仍保持请求顺序。
    def read_dimensions(session, dimensions, profile)
      observations = {}
      reader = CtxDriver::Reader.new(session: session, clock: @clock)
      if (code = prepare_terminal(reader))
        dimensions.each { |name| observations[name] = failure(name, code) }
        return observations
      end
      ordered = dimensions.include?(:configuration) ? [ :configuration, *dimensions.reject { |name| name == :configuration } ] : dimensions
      ordered.each do |name|
        plan = CollectionPlan.new(profile: profile, configuration: observations[:configuration])
        observations[name] = if name == :vpc && !reader.failure && plan.unconfigured?(name)
          Observation.new(name: name, status: :complete, completed_at: @clock.call, issues: [ { code: :vpc_not_configured } ])
        else
          collect_observation(reader, name, plan, profile)
        end
      end
      dimensions.to_h { |name| [ name, observations.fetch(name) ] }
    end

    # 汇总证据完整性，不将查询成功解释为 Fabric 健康。
    def snapshot(target, fabric_key, observations, issues: [])
      Snapshot.new(target: target, fabric_key: fabric_key, observations: observations, observed_at: @clock.call, issues: issues)
    end

    # 采集设备回显前，禁用分页并归一化终端宽度。
    def prepare_terminal(reader)
      PREPARATION_COMMANDS.each do |command|
        capture = reader.read(command)
        return capture.failure.fetch(:code) unless capture.success?
      end
      nil
    end

    # 解析失败限定在单条查询内；Reader 负责传输与回执校验。
    def collect_observation(reader, name, plan, profile)
      command = profile.command(name)
      unavailable = ->(view, capture, details) do
        issue = details.merge(command: command)
        issue[:skipped] = capture.skipped? unless capture.success?
        failure(view, issue.fetch(:code), **issue.except(:code)).with(
          started_at: capture.started_at, completed_at: capture.completed_at, evidence: capture.evidence)
      end
      CtxRunner::Query.new(reader: reader, parser: plan).read(command, names: [ name ], unavailable: unavailable) do |view, result, capture|
        Observation.new(name: view, **result.to_h, started_at: capture.started_at,
          completed_at: capture.completed_at, evidence: capture.evidence)
      end.fetch(name)
    end

    # 构建失败观测，不丢弃已成功的同级维度。
    def failure(name, code, **details)
      Observation.new(name: name, status: :failed, issues: [ { code: code, **details } ], completed_at: @clock.call)
    end
  end
end
