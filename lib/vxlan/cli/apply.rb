# frozen_string_literal: true

require "ctx_cli/apply"
require "ctx_runner/document"
require "ctx_runner/evidence"
require "ctx_runner/execution"
require "vxlan"
require_relative "report"
require_relative "../change_plan"

module Vxlan
  module CLI
    # 原生会话适配：读取使用固定查询提示符，写入由连接器识别配置模式提示符。
    class ApplySession
      # 借用一次已连接且独占的会话，不重连、不重放。
      def initialize(native)
        @native = native
      end

      # 读回完整配置并交给现有解析器；部分证据不能参与前置检查或验收。
      def read_configuration
        [ "terminal length 0", "terminal width 511" ].each { |command| write(command) }
        capture = CtxDriver::Reader.new(session: @native).read("show running-config")
        raise IOError, "Configuration readback failed" unless capture.success?
        observation = Vxlan::Config.new.parse(capture.body, complete: true)
        raise ArgumentError, "Configuration evidence is incomplete" unless observation.complete? && observation.records.one?
        CtxRunner::Document.call(observation.records.first)
      end

      # 每次只发一条命令；失败立即交还宿主，原始输出不进入终端和日志报告。
      def write(command)
        result = @native.execute_command(command.strip, output_sensitive: true)
        raise IOError, "Device command is unconfirmed" unless result.success? && result.steps.one? && result.steps.first.command.text == command.strip
        true
      end
    end

    # 领域适配器只维护计划类型、凭据来源与独占设备会话。
    class Apply
      def initialize(env: ENV, out: $stdout, error: $stderr, input: $stdin, connector_factory: nil, discovery: {})
        @env, @factory, @discovery = env, connector_factory, discovery
        @entry = CtxCli::Apply.new(adapter: self, execution: CtxRunner::Execution, name: "vxlan", out: out, error: error, input: input)
      end

      def run(argv) = @entry.run(argv)

      def select_plan(document, item:)
        CtxRunner::Evidence.plan(document, item: item, platform: "cisco_nxos")
      end

      # 从类型化增量重新生成命令，拒绝修改后的任意脚本。
      def validate_plan(plan)
        change = ChangePlan.build(plan.fetch("change"))
        unless change.commands == plan["commands"] && change.rollback == plan["rollback"]
          raise ArgumentError, "Plan commands were modified"
        end
        change
      end

      def credentials(options)
        require "net/connector/config"
        require "net/connector/credentials"
        env = Net::Connector::Config.new(name: "vxlan", env: @env, env_file: options[:env_file], **@discovery).load_environment.environment
        credentials = Net::Connector::Credentials.new(env: env).resolve(platform: :cisco_nxos)
        raise ArgumentError, "Device username is missing" unless credentials
        credentials.merge(port: options[:port], host_key_policy: "strict", command_timeout: 60, login_timeout: 15)
      end

      def report(options) = Report.new(options.fetch(:directory))

      def with_session(device, settings, &operation)
        return @factory.call(device, settings, &operation) if @factory
        require "net/connector"
        Net::Connector.open(:cisco_nxos, host: device.fetch("host"), **settings) do |native|
          native.with_operation(:vxlan_apply) { operation.call(ApplySession.new(native)) }
        end
      end

      def inspect = "#<#{self.class.name}>"
      alias to_s inspect
      def pretty_print(printer) = printer.text(inspect)
    end
  end
end
