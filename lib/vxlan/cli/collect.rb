# frozen_string_literal: true

require "vxlan"
require "ctx_runner/batch"
require_relative "options"
require_relative "report"
require_relative "connector"

module Vxlan
  module CLI
    # 批量入口拥有配置、清单、并行与报告，不向核心库引入宿主依赖。
    class Collect
      # 可注入清单、传输与执行器，离线集成验证不需要任何真实设备。
      def initialize(env: ENV, out: $stdout, error: $stderr, input: $stdin, connector_factory: nil, executor: nil, **options)
        @env, @out, @error, @input = env, out, error, input
        @connector_factory, @executor = connector_factory, executor
        @defaults = options
      end

      # 先预检全部输入和凭据，再创建报告和连接；失败分类不打印原始异常正文。
      def run(argv)
        # 每次运行独立持有批次状态；预检失败不能改写上一次报告。
        @options, @store, @progress, @devices, @batch = nil, nil, nil, [], nil
        @options = Options.new(argv, env: @env, out: @out, **@defaults)
        return 0 if @options.informational?
        @options.validate_interaction!(input: @input, error: @error)
        @options.load_environment
        if @options.flags[:init]
          @options.initialize_files
          return 0
        end
        return 0 if @options.missing?(input: @input, error: @error)
        @options.load
        require "net/connector/collect/progress"
        @progress = Net::Connector::Collect::Progress.new(io: @error, enabled: !@options.flags[:quiet], verbose: @options.flags[:verbose])
        @progress.notice("配置：#{@options.config}")
        return output(@options.public_values.merge("sources" => @options.sources)) if @options.flags[:show_config]
        @devices = devices = inventory
        return output(devices) if @options.flags[:inventory_only]
        if devices.empty?
          @progress.notice("没有匹配设备，未建立连接")
          @out.puts JSON.generate(status: :no_devices, total: 0) if @options.flags[:json]
          return 1
        end
        credentials = credentials!
        load_network unless @connector_factory && @executor
        unless @connector_factory
          devices.each { |device| Net::Connector::Configuration.new(host: device.fetch("host"), **credentials).validate_endpoint! }
        end
        unless @executor
          require "net/connector/resources"
          Net::Connector::Resources.prepare!(parallel: [ devices.size, @options.values.fetch("parallel") ].min)
        end
        @store = Report.new(@options.values.fetch("directory"), scripts: @options.flags[:scripts] == true)
        @batch = CtxRunner::Batch.new(report: @store, progress: @progress, requested: devices)
        outcome = @batch.run(present: ->(summary) { @out.puts JSON.pretty_generate(summary) if @options.flags[:json] }) do
          @progress.plan(devices: devices, total: @inventory_total, parallel: @options.values.fetch("parallel"), label: "VXLAN 只读采集")
          @progress.with_updates do
            execute(devices) { |device| collect(device, credentials) }
          end
          @store.review_collected_fabric(@options.fabric_policy)
        end
        completion(outcome)
      rescue Interrupt
        diagnostic "采集已取消，已保存的设备报告保留；未保存结果见报告状态"
        130
      rescue SystemCallError, IOError => error
        diagnostic "VXLAN 参数或报告错误：#{report_diagnostic(error)}"
        2
      rescue OptionParser::ParseError, ArgumentError, LoadError => error
        diagnostic "VXLAN 参数、依赖或报告错误：#{error.message}；使用 --help 查看参数"
        2
      rescue StandardError => error
        diagnostic "VXLAN 清单或执行失败：#{CtxDriver::Failure.code(error, :collection_failed)}（#{error.class.name}）"
        2
      end

      private

      # 只在需要库存或网络执行时加载可选依赖，帮助和静态预览保持独立。
      def load_network
        require "net/connector"
      rescue LoadError
        raise LoadError, "联网采集需要 net-connector >= 0.17.0；请在宿主 Gemfile 添加或 gem install net-connector", cause: nil
      end

      # YAML 静态设备或显式 Netdisco 来源二选一；所有重复地址在连接前拒绝。
      def inventory
        values = @options.values
        rows = if @options.dynamic_inventory?
          @progress.reading_inventory
          settings = @options.netdisco_settings
          Net::Connector::Netdisco::Fleet.new(settings: settings).devices.filter_map do |device|
            next unless device.ready? && device.vendor == :cisco_nxos
            { "host" => device.host, "name" => device.name || device.host, "model" => device.model }
          end
        else
          values.fetch("devices")
        end
        targets = @options.normalize_devices(rows)
        @inventory_total = targets.size
        selection = Net::Connector::Inventory::Filters.selection(values)
        targets.select do |device|
          selection.selected?(device.fetch("host"), "cisco_nxos", name: device["name"], model: device["model"])
        end
      end

      # 缺失用户名时不尝试连接；密码允许省略以支持明确的 SSH key/agent。
      def credentials!
        username = secret("NC_CISCO_NXOS_USERNAME") || secret("NC_DEVICE_USERNAME")
        raise ArgumentError, "请设置 NC_DEVICE_USERNAME 或 NC_CISCO_NXOS_USERNAME；密码可通过环境或 SSH key/agent 提供" unless username
        @options.values.fetch("ssh").transform_keys(&:to_sym).merge(username: username,
          password: secret("NC_CISCO_NXOS_PASSWORD") || secret("NC_DEVICE_PASSWORD"), enable_password: secret("NC_ENABLE_PASSWORD"))
      end

      # 空白环境值视为缺失，不修改或回显凭据。
      def secret(name)
        value = @options.environment[name]
        value unless value.nil? || value.strip.empty?
      end

      # 每个任务使用独立 Collector 和会话；公共执行器负责有界并发和线程回收。
      def execute(devices, &block)
        parallel = @options.values.fetch("parallel")
        return @executor.call(devices, parallel, &block) if @executor
        Net::Connector::Parallel::Pool.new(parallel: parallel).map(devices, &block)
      end

      # 单台失败保留其他设备和已获得维度；报告持久化失败交由批次终止处理。
      def collect(device, credentials)
        credentials = credentials.merge(on_event: @progress.method(:event))
        @batch.collect(device) do
          connector = @connector_factory ? @connector_factory.call(device, credentials) : Connector.new(device, credentials)
          snapshot = Vxlan::Collector.new.collect(connector: connector, target: device, fabric_key: @options.values.fetch("fabric"),
            model: device["model"], dimensions: @options.values.fetch("dimensions").map(&:to_sym))
          snapshot
        end
      end

      # Runner 决定批次结论；CLI 仅呈现安全诊断并映射退出码。
      def completion(outcome)
        if outcome.finalization_error
          diagnostic "VXLAN 摘要报告错误：#{outcome.finalization_error}"
        end
        if outcome.recovery_failed
          diagnostic "摘要恢复未确认；请依据退出码及报告目录检查，不能将旧摘要视为本次成功。"
        end
        if outcome.status == :interrupted
          diagnostic "采集已取消，已保存的设备报告保留；未保存结果见报告状态"
        elsif (failure = outcome.failure)
          if failure[:kind] == :report
            diagnostic "VXLAN 参数或报告错误：#{failure[:detail]}"
          else
            diagnostic "VXLAN 清单或执行失败：#{failure[:error_type]}；已采集结果见批次报告"
          end
        end
        { complete: 0, incomplete: 1, failed: 2, interrupted: 130 }.fetch(outcome.status)
      end

      # 错误提示失败不能覆盖取消或执行退出码；已失效的进度流不再重试。
      def diagnostic(message)
        return if @progress&.output_error
        @error.puts(message)
      rescue StandardError
        nil
      end

      # 自有发布错误消息不含正文；外部文件异常只显示类型，不打印 message/cause。
      def report_diagnostic(error)
        error.instance_of?(Report::Error) ? error.message : error.class.name
      end

      # 预览默认显示逐设备身份；公开配置由显式开关展示。
      def output(value)
        if @options.flags[:json] || value.is_a?(Hash)
          @out.puts JSON.pretty_generate(value)
        else
          value.each { |device| @out.puts "#{device.fetch('host')}\t#{device.fetch('name')}\t#{device['model']}" }
          @out.puts "设备：#{value.size} 台；未建立设备连接"
        end
        value.is_a?(Array) && value.empty? ? 1 : 0
      end
    end
  end
end
