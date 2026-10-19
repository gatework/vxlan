# frozen_string_literal: true

require "vxlan"
require_relative "options"
require_relative "report"
require_relative "parallel"

module Vxlan
  module CLI
    # 可选传输适配器；只由联网采集使用，解析库不引用 net-connector。
    class NativeConnector
      # 固定设备与接入选项，不在构造时建立会话。
      def initialize(device, settings)
        @device, @settings = device, settings
      end

      # 向 Collector 声明已知平台，不把品牌猜测当作型号识别。
      def platform = :cisco_nxos

      # 连接器拥有原生会话；CtxDriver 仅借用，不负责关闭或重连。
      def open
        Net::Connector.open(:cisco_nxos, host: @device.fetch("host"), **@settings) do |native|
          native.with_operation(:vxlan) { yield native }
        end
      end
    end

    # 批量入口拥有配置、清单、并行与报告，不向核心库引入宿主依赖。
    class Collect
      # 可注入清单、传输与执行器，离线集成验证不需要任何真实设备。
      def initialize(env: ENV, out: $stdout, error: $stderr, input: $stdin, connector_factory: nil, executor: nil, **options)
        @env, @out, @error, @input = env, out, error, input
        @connector_factory, @executor = connector_factory, executor
        @defaults = options
        @lock, @results = Mutex.new, []
      end

      # 先预检全部输入和凭据，再创建报告和连接；失败分类不打印原始异常正文。
      def run(argv)
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
        progress("配置：#{@options.config}")
        return output(@options.values) if @options.flags[:show_config]
        @devices = devices = inventory
        return output(devices) if @options.flags[:inventory_only]
        if devices.empty?
          progress("没有匹配设备，未建立连接")
          @out.puts JSON.generate(status: :no_devices, total: 0) if @options.flags[:json]
          return 1
        end
        credentials = credentials!
        load_network unless @connector_factory && @executor
        unless @connector_factory
          devices.each { |device| Net::Connector::Configuration.new(host: device.fetch("host"), **credentials).validate_endpoint! }
        end
        @store = Report.new(@options.values.fetch("directory"))
        progress("VXLAN 只读采集 | 本次 #{devices.size} 台；并发 #{@options.values.fetch('parallel')}")
        execute(devices) { |device| collect(device, credentials) }
        summary = finish
        return 2 unless summary
        summary[:status] == :complete ? 0 : 1
      rescue Interrupt
        finish(interrupted: true) if @store
        @error.puts "采集已取消，已保存的设备报告保留；未保存结果见报告状态"
        130
      rescue SystemCallError, IOError => error
        finish(report_error: error) if @store
        @error.puts "VXLAN 参数或报告错误：#{report_diagnostic(error)}"
        2
      rescue OptionParser::ParseError, ArgumentError, LoadError => error
        if @store
          finish(execution_error: error)
          @error.puts "VXLAN 执行失败：#{error.class.name}；已采集结果见批次报告"
        else
          @error.puts "VXLAN 参数、依赖或报告错误：#{error.message}；使用 --help 查看参数"
        end
        2
      rescue StandardError => error
        finish(execution_error: error) if @store
        @error.puts "VXLAN 清单或执行失败：#{CtxDriver::Failure.code(error, :collection_failed)}（#{error.class.name}）"
        2
      end

      private

      # 只在需要库存或网络执行时加载可选依赖，帮助和静态预览保持独立。
      def load_network
        require "net/connector"
      rescue LoadError
        raise LoadError, "联网采集需要 net-connector >= 0.14.1；请在宿主 Gemfile 添加或 gem install net-connector", cause: nil
      end

      # YAML 静态设备或显式 Netdisco 来源二选一；所有重复地址在连接前拒绝。
      def inventory
        values = @options.values
        rows = if values["netdisco_config"]
          require "net/connector/netdisco"
          settings = Net::Connector::Netdisco::Settings.from_file(values.fetch("netdisco_config"), env: @env)
          Net::Connector::Netdisco::Fleet.new(settings: settings).devices.filter_map do |device|
            next unless device.ready? && device.vendor == :cisco_nxos
            { "host" => device.host, "name" => device.name || device.host, "model" => device.model }
          end
        else
          values.fetch("devices")
        end
        targets = rows.map { |row| normalize_device(row) }
        raise ArgumentError, "设备清单包含重复管理地址" unless targets.map { |r| r.fetch("host") }.uniq.size == targets.size
        includes = values.fetch("hosts").map { |v| IPAddr.new(v) }
        excludes = values.fetch("exclude_hosts").map { |v| IPAddr.new(v) }
        targets.select do |device|
          host, name = device.values_at("host", "name")
          (includes.empty? || includes.any? { |network| network.include?(host) }) &&
            excludes.none? { |network| network.include?(host) } &&
            (values.fetch("names").empty? || values.fetch("names").any? { |v| name.downcase.include?(v.downcase) }) &&
            values.fetch("exclude_names").none? { |v| name.downcase.include?(v.downcase) }
        end
      end

      # 设备身份只接受公开字段，拒绝隐藏在 YAML 中的密码或连接参数。
      def normalize_device(row)
        unless row.is_a?(Hash) && (row.keys - %w[host name model]).empty? && row["host"].is_a?(String) && !row["host"].include?("/")
          raise ArgumentError, "devices 仅接受 host、name、model，host 须为单个 IP"
        end
        host = IPAddr.new(row.fetch("host")).to_s
        %w[name model].each { |key| raise ArgumentError, "设备 #{key} 须为非空字符串" if row.key?(key) && !row[key].nil? && (!row[key].is_a?(String) || row[key].strip.empty?) }
        { "host" => host, "name" => row["name"] || host, "model" => row["model"] }.freeze
      rescue IPAddr::Error
        raise ArgumentError, "设备 host 无效", cause: nil
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
        value = @env[name]
        value unless value.nil? || value.strip.empty?
      end

      # 每个任务使用独立 Collector 和会话；宿主调度不依赖连接器内部命名。
      def execute(devices, &block)
        parallel = @options.values.fetch("parallel")
        return @executor.call(devices, parallel, &block) if @executor
        Parallel.map(devices, parallel: parallel, &block)
      end

      # 单台失败保留其他设备和已获得维度；报告持久化失败交由批次终止处理。
      def collect(device, credentials)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        snapshot = nil
        begin
          connector = @connector_factory ? @connector_factory.call(device, credentials) : NativeConnector.new(device, credentials)
          snapshot = Vxlan::Collector.new.collect(connector: connector, target: device, fabric_key: @options.values.fetch("fabric"),
            model: device["model"], dimensions: @options.values.fetch("dimensions").map(&:to_sym))
          dimensions = snapshot.dimensions.transform_values { |v| { status: v.status, records: v.records.size, issues: v.issues.map { |issue| issue[:code] }.uniq } }
          status = snapshot.dimensions.fetch(:collection).status
          result = { device: device, status: status, dimensions: dimensions }
        rescue StandardError => error
          result = { device: device, status: :failed, error: CtxDriver::Failure.code(error, :collection_failed), dimensions: {} }
        end
        result[:duration_ms] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
        result[:report_saved] = false
        @lock.synchronize { @results << result }
        @store.write(result, snapshot: snapshot)
        @lock.synchronize do
          result[:report_saved] = true
          progress("已采集 #{@results.size} 台 | #{device.fetch('host')} #{result[:status]}；报告已保存；#{result[:duration_ms]} ms") if @options.flags[:verbose] || result[:status] != :complete || (@results.size % 10).zero?
        end
        result
      end

      # 调度器已回收线程；摘要失败只交付安全诊断，不覆盖先前的取消事实。
      def finish(interrupted: false, report_error: nil, execution_error: nil)
        summary = @store.finish(@results.sort_by { |r| r[:device]["host"] }, interrupted: interrupted, requested: @devices,
          report_error: report_error && report_diagnostic(report_error), execution_error: execution_error&.class&.name)
        output_summary(summary)
        summary
      rescue SystemCallError, IOError => error
        @error.puts "VXLAN 摘要报告错误：#{report_diagnostic(error)}"
        nil
      end

      # 自有发布错误消息不含正文；外部文件异常只显示类型，不打印 message/cause。
      def report_diagnostic(error)
        error.instance_of?(Report::Error) ? error.message : error.class.name
      end

      # 进度固定输出 stderr，JSON stdout 不混入人类提示。
      def progress(message)
        return if @options&.flags&.fetch(:quiet, false)
        @error.puts "[#{Time.now.strftime('%H:%M:%S')}] #{message}"
        @error.flush
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

      # 批次摘要区分完整证据与健康结论，并给出可追溯的报告路径。
      def output_summary(summary)
        if @options.flags[:json]
          @out.puts JSON.pretty_generate(summary)
        else
          counts = summary.fetch(:counts)
          saved = summary.fetch(:devices).count { |result| result[:report_saved] }
          @out.puts "VXLAN 采集：本次 #{summary.fetch(:total)} 台；已采集 #{summary.fetch(:completed)} 台；报告已保存 #{saved} 台；完整 #{counts.fetch(:complete, 0)}，部分 #{counts.fetch(:partial, 0)}，失败 #{counts.fetch(:failed, 0)}；结果 #{summary.fetch(:status)}"
          @out.puts "证据完整性不代表 Fabric 健康。"
          @out.puts "报告：#{File.join(@store.directory, 'summary.txt')}"
        end
      end
    end
  end
end
