# frozen_string_literal: true

require "ctx_cli/apply"
require "ctx_runner/document"
require "ctx_runner/evidence"
require "ctx_runner/execution"
require "ctx_runner/configuration_session"
require "vxlan"
require_relative "report"
require_relative "../change_plan"

module Vxlan
  module CLI
    # 领域仅声明准备命令及配置语法，共享会话维护回执和读取边界。
    class ApplySession < CtxRunner::ConfigurationSession
      def initialize(native)
        super(session: CtxDriver::Session.new(native), preparation_commands: [ "terminal length 0", "terminal width 511" ],
          configuration_command: "show running-config", parser: Vxlan::Config.new)
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
