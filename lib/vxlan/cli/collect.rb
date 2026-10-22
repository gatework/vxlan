# frozen_string_literal: true

require "ctx_cli/collection"
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

      # 公共入口编排顺序与失败收尾；以下方法是显式领域适配协议。
      def run(argv)
        progress = ->(options) do
          require "net/connector/collect/progress"
          Net::Connector::Collect::Progress.new(io: @error, enabled: !options.flags[:quiet], verbose: options.flags[:verbose])
        end
        CtxCli::Collection.new(adapter: self, options: ->(arguments) { Options.new(arguments, env: @env, out: @out, **@defaults) },
          progress: progress, batch: CtxRunner::Batch, label: "VXLAN", report_error: Report::Error,
          failure_code: ->(error) { CtxDriver::Failure.code(error, :collection_failed) },
          out: @out, error: @error, input: @input).run(argv)
      end

      # 只在需要库存或网络执行时加载可选依赖，帮助和静态预览保持独立。
      def load_network
        require "net/connector"
      rescue LoadError
        raise LoadError, "联网采集需要 net-connector >= 0.16.0；请在宿主 Gemfile 添加或 gem install net-connector", cause: nil
      end

      # YAML 静态设备或显式 Netdisco 来源二选一；所有重复地址在连接前拒绝。
      def inventory(options, progress:)
        values = options.values
        rows = if options.dynamic_inventory?
          progress.reading_inventory
          settings = options.netdisco_settings
          Net::Connector::Netdisco::Fleet.new(settings: settings).devices.filter_map do |device|
            next unless device.ready? && device.vendor == :cisco_nxos
            { "host" => device.host, "name" => device.name || device.host, "model" => device.model }
          end
        else
          values.fetch("devices")
        end
        targets = options.normalize_devices(rows)
        total = targets.size
        selection = Net::Connector::Inventory::Filters.selection(values)
        selected = targets.select do |device|
          selection.selected?(device.fetch("host"), "cisco_nxos", name: device["name"], model: device["model"])
        end
        [ selected, total ]
      end

      # 所有设备先完成凭据、端点与资源预检，再允许创建报告和连接。
      def prepare(devices, options)
        credentials = credentials!(options)
        load_network unless @connector_factory && @executor
        unless @connector_factory
          devices.each { |device| Net::Connector::Configuration.new(host: device.fetch("host"), **credentials).validate_endpoint! }
        end
        unless @executor
          require "net/connector/resources"
          begin
            Net::Connector::Resources.prepare!(parallel: [ devices.size, options.values.fetch("parallel") ].min)
          rescue ArgumentError
            raise CtxCli::Collection::Error, "本机文件描述符额度不足；请提高终端 ulimit -n 或降低 --parallel。已停止，未连接设备。", cause: nil
          end
        end
        credentials
      end

      def report(options)
        Report.new(options.values.fetch("directory"), scripts: options.flags[:scripts] == true)
      rescue ArgumentError
        raise CtxCli::Collection::Error, "报告目录无效；请使用真实私有目录、权限0700，并检查目录路径。", cause: nil
      end
      def after_collect(report, options) = report.review_collected_fabric(options.fabric_policy)

      # 缺失用户名时不尝试连接；密码允许省略以支持明确的 SSH key/agent。
      def credentials!(options)
        username = secret(options, "NC_CISCO_NXOS_USERNAME") || secret(options, "NC_DEVICE_USERNAME")
        raise CtxCli::Collection::Error, "请设置 NC_DEVICE_USERNAME 或 NC_CISCO_NXOS_USERNAME；密码可通过环境或 SSH key/agent 提供" unless username
        options.values.fetch("ssh").transform_keys(&:to_sym).merge(username: username,
          password: secret(options, "NC_CISCO_NXOS_PASSWORD") || secret(options, "NC_DEVICE_PASSWORD"), enable_password: secret(options, "NC_ENABLE_PASSWORD"))
      end

      # 空白环境值视为缺失，不修改或回显凭据。
      def secret(options, name)
        value = options.environment[name]
        value unless value.nil? || value.strip.empty?
      end

      # 每个任务使用独立 Collector 和会话；公共执行器负责有界并发和线程回收。
      def execute(devices, options, &block)
        parallel = options.values.fetch("parallel")
        return @executor.call(devices, parallel, &block) if @executor
        Net::Connector::Parallel::Pool.new(parallel: parallel).map(devices, &block)
      end

      # 单台失败保留其他设备和已获得维度；报告持久化失败交由批次终止处理。
      def collect(device, options, context:, progress:)
        credentials = context.merge(on_event: progress.method(:event))
        connector = @connector_factory ? @connector_factory.call(device, credentials) : Connector.new(device, credentials)
        snapshot = Vxlan::Collector.new.collect(connector: connector, target: device, fabric_key: options.values.fetch("fabric"),
          model: device["model"], dimensions: options.values.fetch("dimensions").map(&:to_sym))
        snapshot
      end

      private :load_network, :credentials!, :secret
    end
  end
end
