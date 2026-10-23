# frozen_string_literal: true

require "optparse"
require "ctx_cli/terminal"
require "ctx_cli/input"
require "json"
require "ctx_runner/document"
require "digest"
require "ctx_runner/execution"
require "ipaddr"
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
        raise IOError, "Device command is unconfirmed" unless result.success? && result.steps.one?
        true
      end
    end

    # 交互式单设备下发：展示、确认、重新读取、记录意图、执行、回读，禁止无人值守确认。
    class Apply
      # 注入连接工厂仅用于宿主集成和离线失败测试。
      def initialize(env: ENV, out: $stdout, error: $stderr, input: $stdin, connector_factory: nil, discovery: {})
        @env, @out, @error, @input, @factory = env, out, error, input, connector_factory
        @discovery = discovery
      end

      # 没有 --yes 或自动回退；零退出码只确认配置回读，不声称业务已验收。
      def run(argv)
        @store, @execution = nil, nil
        options = { directory: File.join(Dir.pwd, "vxlan-executions"), port: 22 }
        parser = OptionParser.new do |p|
          p.banner = "Usage: vxlan apply --plan FILE --item ID [--env-file FILE] (requires explicit confirmation in an interactive terminal)"
          p.on("--plan FILE", "Batch plan.json; requires a SHA256 checksum file in the same directory") { |value| options[:plan] = value }
          p.on("--item ID", "Explicitly select one change from the batch plan; bulk execution is prohibited") { |value| options[:item] = value }
          p.on("--env-file FILE", "Explicit credentials file; process environment takes precedence") { |value| options[:env_file] = value }
          p.on("--directory DIR", "Private execution log directory") { |value| options[:directory] = value }
          p.on("--port N", Integer, "SSH port, default 22") { |value| options[:port] = value }
          p.on("-h", "--help", "Show help without connecting to devices") { options[:help] = true }
        end
        rest = parser.parse(argv.dup)
        return @out.puts(parser) || 0 if options[:help]
        terminal = CtxCli::Terminal.new(input: @input, out: @out)
        terminal.require_tty!(@error)
        raise ArgumentError, "A single plan is required" unless rest.empty? && options[:plan] && options[:port].between?(1, 65_535)
        body = CtxCli::Input.read(path: options[:plan])
        hash = Digest::SHA256.hexdigest(body)
        plan = CtxParser::Immutable.copy(select_plan(JSON.parse(body), options, hash))
        change = validate_plan(plan)
        host = plan.fetch("device").fetch("host")
        @out.puts "Target: #{plan['device']['name']}(#{host}); #{plan['scope']}; #{plan['title']}"
        @out.puts "Impact: #{plan['impact']}"
        @out.puts Array(plan["prerequisites"]).map { |value| "Prerequisite: #{value}" }
        @out.puts "Plan SHA256: #{hash}\nProposed commands:\n#{change.commands.join("\n")}\nConditional rollback (not executed automatically):\n#{change.rollback.join("\n")}"
        token = "APPLY #{host} #{hash[0, 12]} #{options[:item]}"
        confirmed = terminal.confirm(token: token, prompt: "After confirming the service policy and maintenance window, enter #{token}; any other input cancels: ")
        return @out.puts("Cancelled; no device connection opened.") || 1 unless confirmed
        settings = credentials(options)
        @store = Report.new(options[:directory])
        @execution = CtxRunner::Execution.new(plan: plan, change: change, journal: @store, plan_sha256: hash, item: options[:item])
        @execution.run { |operation| with_session(plan["device"], settings, &operation) }
        @out.puts "Configuration readback confirmed; service acceptance is still required. Configuration was not saved to startup configuration. Log: #{@store.directory}/execution.json"
        0
      rescue Interrupt
        report_journal_failure
        @error.puts "Operation interrupted; #{@execution&.started? ? 'Device effects may be incomplete; read back and verify before proceeding. Do not replay commands.' : 'No service configuration was sent.'}"
        130
      rescue StandardError, LoadError => error
        report_journal_failure
        @error.puts "Apply stopped (#{error.class.name}); #{@execution&.started? ? 'Effects are not fully confirmed; read back first. No automatic replay or rollback.' : 'No service configuration was sent; check the terminal, plan, credentials and current configuration for consistency.'}"
        2
      end

      private

      # 聚合文件必须校验哈希并选中唯一动作；绝不隐式选择第一项或循环执行。
      def select_plan(document, options, hash)
        id = options[:item]
        unless document.is_a?(Hash) && document["schema_version"] == 2 && document["platform"] == "cisco_nxos" && document["changes"].is_a?(Hash) &&
            id.is_a?(String) && id.match?(/\A[A-Za-z0-9_.-]+\z/) && document["changes"].key?(id)
          raise ArgumentError, "A batch plan and valid --item are required"
        end
        raise ArgumentError, "Plan checksum verification failed" unless CtxCli::Input.read(path: "#{options[:plan]}.sha256", max_bytes: 128).strip == hash
        document["changes"].fetch(id)
      end

      # 不信任文件中的命令，重新从有限动作渲染并逐字核对，拒绝额外命令。
      def validate_plan(plan)
        raise ArgumentError, "Plan type mismatch" unless plan.is_a?(Hash) && plan["schema_version"] == 1 && plan["platform"] == "cisco_nxos"
        host = plan.fetch("device").fetch("host")
        raise ArgumentError, "Invalid target address" unless host.is_a?(String) && !host.include?("/") && IPAddr.new(host).to_s == host
        raise ArgumentError, "Invalid configuration fingerprint" unless plan["expected_config_sha256"].is_a?(String) && plan["expected_config_sha256"].match?(/\A[0-9a-f]{64}\z/)
        change = ChangePlan.build(plan.fetch("change"))
        raise ArgumentError, "Plan commands were modified" unless change.commands == plan["commands"] && change.rollback == plan["rollback"]
        change
      end

      # 共用分层环境加载器，显式文件最高、进程环境优先；凭据不进入计划或日志。
      def credentials(options)
        require "net/connector/config"
        env = Net::Connector::Config.new(name: "vxlan", env: @env, env_file: options[:env_file], **@discovery).load_environment.environment
        username = env["NC_CISCO_NXOS_USERNAME"] || env["NC_DEVICE_USERNAME"]
        raise ArgumentError, "Device username is missing" unless username.is_a?(String) && !username.strip.empty?
        { username: username, password: env["NC_CISCO_NXOS_PASSWORD"] || env["NC_DEVICE_PASSWORD"], enable_password: env["NC_ENABLE_PASSWORD"],
          port: options[:port], host_key_policy: "strict", command_timeout: 60, login_timeout: 15 }
      end

      # 原生会话只打开一次，读写处于同一操作租约中。
      def with_session(device, settings, &operation)
        return @factory.call(device, settings, &operation) if @factory
        require "net/connector"
        Net::Connector.open(:cisco_nxos, host: device.fetch("host"), **settings) do |native|
          native.with_operation(:vxlan_apply) { operation.call(ApplySession.new(native)) }
        end
      end

      # 公共执行器保存失败状态；CLI 只呈现持久性尚未确认的诊断。
      def report_journal_failure
        return unless @execution&.journal_failed?
        @error.puts "Execution log finalization is unconfirmed; existing checkpoints retained. Do not replay configuration based on this state."
      rescue StandardError, Interrupt
        nil
      end
    end
  end
end
