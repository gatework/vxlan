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
        raise LoadError, "Online collection requires net-connector >= 0.19.0; add it to the host Gemfile or run gem install net-connector", cause: nil
      end

      # YAML 静态设备或显式 Netdisco 来源二选一；选中地址的所有冲突记录在连接前拒绝。
      def inventory(options, progress:)
        values = options.values
        selection = Net::Connector::Inventory::Filters.selection(values)
        rows = if options.dynamic_inventory?
          progress.reading_inventory
          settings = options.netdisco_settings
          policy = settings.snapshot(mode: :inventory)
          devices = Net::Connector::Netdisco::Catalog.new(settings: settings).devices(policy: policy)
          devices.filter_map(&:issue).tally.each { |code, count| progress.notice("Inventory: #{code}=#{count}") }
          devices.filter_map do |device|
            next unless device.vendor == :cisco_nxos
            platform = "cisco_nxos"
            if device.issue == :duplicate_host && policy.rules.selected?(device.host, device.vendor, name: device.name, model: device.model) &&
                selection.selected?(device.host, platform, name: device.name || device.host, model: device.model)
              raise CtxCli::Collection::Error, "Duplicate management address in selected inventory"
            end
            next unless device.ready?
            { "host" => device.host, "name" => device.name || device.host, "model" => device.model }
          end
        else
          values.fetch("devices")
        end
        targets = options.normalize_devices(rows)
        total = targets.size
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
            raise CtxCli::Collection::Error, "Insufficient local file descriptor limit; raise the terminal ulimit -n or lower --parallel. Stopped without connecting to devices.", cause: nil
          end
        end
        credentials
      end

      def report(options)
        Report.new(options.values.fetch("directory"), scripts: options.flags[:scripts] == true)
      rescue ArgumentError
        raise CtxCli::Collection::Error, "Invalid report directory; use a real private directory with mode 0700 and check its path.", cause: nil
      end
      def after_collect(report, options) = report.review_collected_fabric(options.fabric_policy)

      # 缺失用户名时不尝试连接；密码允许省略以支持明确的 SSH key/agent。
      def credentials!(options)
        require "net/connector/credentials"
        credentials = Net::Connector::Credentials.new(env: options.environment).resolve(platform: :cisco_nxos)
        raise CtxCli::Collection::Error, "Set NC_DEVICE_USERNAME or platform NC_*_USERNAME; provide a password through the environment or use an SSH key/agent" unless credentials
        options.values.fetch("ssh").transform_keys(&:to_sym).merge(credentials)
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

      private :load_network, :credentials!
    end
  end
end
