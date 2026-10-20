# frozen_string_literal: true

require "optparse"
require "json"
require "digest"
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
        raise IOError, "配置回读失败" unless capture.success?
        observation = Vxlan::Config.new.parse(capture.body, complete: true)
        raise ArgumentError, "配置证据不完整" unless observation.complete? && observation.records.one?
        JSON.parse(JSON.generate(observation.records.first))
      end

      # 每次只发一条命令；失败立即交还宿主，原始输出不进入终端和日志报告。
      def write(command)
        result = @native.execute_command(command.strip, output_sensitive: true)
        raise IOError, "设备命令未确认" unless result.success? && result.steps.one?
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
        @store, @state, @started = nil, nil, false
        options = { directory: File.join(Dir.pwd, "vxlan-executions"), port: 22 }
        parser = OptionParser.new do |p|
          p.banner = "用法：vxlan apply --plan FILE --item ID [--env-file FILE]（必须真实终端明确确认）"
          p.on("--plan FILE", "批次 plan.json，须有同目录 SHA256 校验文件") { |value| options[:plan] = value }
          p.on("--item ID", "批次计划中明确选择一个增量，禁止批量执行") { |value| options[:item] = value }
          p.on("--env-file FILE", "显式凭据文件，进程环境优先") { |value| options[:env_file] = value }
          p.on("--directory DIR", "私有执行日志目录") { |value| options[:directory] = value }
          p.on("--port N", Integer, "SSH 端口，默认 22") { |value| options[:port] = value }
          p.on("-h", "--help", "查看帮助，不连接设备") { options[:help] = true }
        end
        rest = parser.parse(argv.dup)
        return @out.puts(parser) || 0 if options[:help]
        raise ArgumentError, "必须使用真实交互终端" unless @input.tty? && @out.tty? && @error.tty?
        raise ArgumentError, "需要单个计划" unless rest.empty? && options[:plan] && options[:port].between?(1, 65_535)
        body = File.read(options[:plan])
        hash = Digest::SHA256.hexdigest(body)
        plan = CtxParser::Immutable.copy(select_plan(JSON.parse(body), options, hash))
        change = validate_plan(plan)
        host = plan.fetch("device").fetch("host")
        @out.puts "目标：#{plan['device']['name']}（#{host}）；#{plan['scope']}；#{plan['title']}"
        @out.puts "影响：#{plan['impact']}"
        @out.puts Array(plan["prerequisites"]).map { |value| "条件：#{value}" }
        @out.puts "计划 SHA256：#{hash}\n拟执行命令：\n#{change.commands.join("\n")}\n条件回退（不自动执行）：\n#{change.rollback.join("\n")}"
        token = "APPLY #{host} #{hash[0, 12]} #{options[:item]}"
        @out.print "确认业务策略及维护窗口后输入 #{token}；其他输入取消："
        @out.flush
        return @out.puts("已取消，未连接设备。") || 1 unless @input.gets&.strip == token
        settings = credentials(options)
        @store = Report.new(options[:directory])
        @state = { "status" => "confirmed", "device" => plan["device"], "plan_sha256" => hash, "plan_item" => options[:item], "expected_config_sha256" => plan["expected_config_sha256"], "commands" => plan["commands"], "steps" => [] }
        @store.write_execution(@state)
        session_opened, verified = false, false
        with_session(plan["device"], settings) do |session|
          raise IOError, "会话回调重复，禁止重放" if session_opened
          session_opened = true
          before = CtxParser::Immutable.copy(session.read_configuration)
          unless ChangePlan.fingerprint(before) == plan["expected_config_sha256"] && change.eligible?(before)
            raise ArgumentError, "配置已变化或增量前提不满足"
          end
          change.commands.each_with_index do |command, index|
            @state["status"] = "executing"
            @state["pending_command"] = index
            @store.write_execution(@state)
            @started = true
            raise IOError, "设备命令未确认" unless session.write(command) == true
            @state["steps"] << { "index" => index, "status" => "acknowledged" }
            @state.delete("pending_command")
            @store.write_execution(@state)
          end
          after = CtxParser::Immutable.copy(session.read_configuration)
          raise IOError, "配置验收未通过" unless change.satisfied?(after, before: before)
          @state["observed_config_sha256"] = ChangePlan.fingerprint(after)
          verified = true
        end
        raise IOError, "会话未完成配置验证" unless verified
        @state["status"] = "configuration_verified"
        @store.write_execution(@state)
        @out.puts "配置回读已确认；仍需完成业务验收，未执行保存配置。日志：#{@store.directory}/execution.json"
        0
      rescue Interrupt
        record_failure("interrupted")
        @error.puts "操作中断；#{@started ? '设备效果可能不完整，请先回读核对，禁止重放。' : '尚未下发业务配置。'}"
        130
      rescue StandardError, LoadError => error
        record_failure(error.class.name)
        @error.puts "下发停止（#{error.class.name}）；#{@started ? '效果未完整确认，先回读，不自动重放或回退。' : '未下发业务配置；检查终端、计划、凭据及当前配置是否仍匹配。'}"
        2
      end

      private

      # 聚合文件必须校验哈希并选中唯一动作；绝不隐式选择第一项或循环执行。
      def select_plan(document, options, hash)
        id = options[:item]
        unless document.is_a?(Hash) && document["schema_version"] == 2 && document["platform"] == "cisco_nxos" && document["changes"].is_a?(Hash) &&
            id.is_a?(String) && id.match?(/\A[A-Za-z0-9_.-]+\z/) && document["changes"].key?(id)
          raise ArgumentError, "需要批次计划及有效 --item"
        end
        raise ArgumentError, "计划校验失败" unless File.read("#{options[:plan]}.sha256").strip == hash
        document["changes"].fetch(id)
      end

      # 不信任文件中的命令，重新从有限动作渲染并逐字核对，拒绝额外命令。
      def validate_plan(plan)
        raise ArgumentError, "计划类型不匹配" unless plan.is_a?(Hash) && plan["schema_version"] == 1 && plan["platform"] == "cisco_nxos"
        host = plan.fetch("device").fetch("host")
        raise ArgumentError, "目标地址无效" unless host.is_a?(String) && !host.include?("/") && IPAddr.new(host).to_s == host
        raise ArgumentError, "配置指纹无效" unless plan["expected_config_sha256"].is_a?(String) && plan["expected_config_sha256"].match?(/\A[0-9a-f]{64}\z/)
        change = ChangePlan.build(plan.fetch("change"))
        raise ArgumentError, "计划命令被修改" unless change.commands == plan["commands"] && change.rollback == plan["rollback"]
        change
      end

      # 共用分层环境加载器，显式文件最高、进程环境优先；凭据不进入计划或日志。
      def credentials(options)
        require "net/connector/config"
        env = Net::Connector::Config.new(name: "vxlan", env: @env, env_file: options[:env_file], **@discovery).load_environment.environment
        username = env["NC_CISCO_NXOS_USERNAME"] || env["NC_DEVICE_USERNAME"]
        raise ArgumentError, "缺少设备用户名" unless username.is_a?(String) && !username.strip.empty?
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

      # 失败记录尽力持久化；记录失败也不允许继续发送任何命令。
      def record_failure(code)
        return unless @store && @state
        @state["status"] = @started ? "uncertain" : "failed"
        @state["error"] = code
        @store.write_execution(@state)
      rescue StandardError, Interrupt
        @error.puts "执行日志收尾未确认；保留已有检查点，禁止据此重放配置。"
      end
    end
  end
end
