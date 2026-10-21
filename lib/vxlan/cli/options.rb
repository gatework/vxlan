# frozen_string_literal: true

require "optparse"
require "net/connector/inventory/filters"
require "yaml"
require "ipaddr"
require "fileutils"
require "tempfile"

module Vxlan
  module CLI
    # 采集入口的公开参数；凭据始终留在环境中，不传入解析库或 YAML。
    class Options
      FIELDS = (%w[fabric fabric_policy devices netdisco inventory netdisco_config parallel directory dimensions ssh] + Net::Connector::Inventory::Filters::FIELDS).freeze
      SSH_FIELDS = %w[port command_timeout login_timeout host_key_policy known_hosts].freeze
      SSH_DEFAULTS = { "host_key_policy" => "strict", "command_timeout" => 60, "login_timeout" => 15 }.freeze
      attr_reader :values, :config, :env_file, :flags, :fabric_policy, :environment

      PATH_FIELDS = %w[directory fabric_policy netdisco_config ssh.known_hosts netdisco.cache_directory netdisco.db_sslrootcert].freeze

      # 文件发现由共享加载器负责；这里只保存调用入口和领域参数。
      def initialize(argv, env:, out:, config: nil, env_file: nil, directory: File.join(Dir.pwd, "vxlans"), discovery: {}, command: "vxlan collect")
        @process_environment, @out = env.to_h.dup, out
        @directory, @command, @discovery = directory, command, discovery
        @explicit_config, @explicit_env_file = config, env_file
        @overrides, @flags = {}, {}
        @parser = parser
        @parser.parse!(argv.dup).tap { |rest| raise ArgumentError, "不接受位置参数" unless rest.empty? }
      end

      # 帮助和范例只打印文本，不读取文件或加载可选网络依赖。
      def informational?
        if flags[:help] || flags[:help_all]
          @out.puts @parser
          if flags[:help_all]
            @out.puts "环境默认：VXLAN_CONFIG、VXLAN_FABRIC、VXLAN_PARALLEL（或 NC_PARALLEL）、VXLAN_DIRECTORY。"
            @out.puts "凭据：NC_DEVICE_USERNAME / NC_DEVICE_PASSWORD，或 NC_CISCO_NXOS_USERNAME / NC_CISCO_NXOS_PASSWORD；可选 NC_ENABLE_PASSWORD。"
            @out.puts "优先级：CLI > 进程环境 > YAML > .env > 内置默认值。YAML/.env 路径基于来源目录；CLI 路径基于启动目录。默认报告：#{@directory}"
          end
        elsif flags[:examples]
          @out.puts "常用示例（地址须替换为实际清单地址）：\n  初始化缺失文件后退出：\n    #{@command} --init --non-interactive\n  预览筛选清单：\n    #{@command} --host 192.0.2.10 --plan\n  按名称选择设备：\n    #{@command} --name leaf --exclude-name spare -p 4\n  自动化采集摘要：\n    #{@command} --dimensions configuration,nve_peers --json --no-progress"
        else
          return false
        end
        true
      end

      # 自动化拒绝强制问答；帮助分支无需检查终端或消费输入。
      def validate_interaction!(input:, error:)
        if flags[:interactive] && !(input.tty? && error.tty?)
          raise ArgumentError, "--interactive 需要交互终端；自动化请使用 --init --non-interactive"
        end
      end

      # 只在采集/初始化时加载共享文件服务，不改写进程环境。
      def load_environment
        require "net/connector/config"
        @files = Net::Connector::Config.new(name: "vxlan", env: @process_environment,
          config: @explicit_config, env_file: @explicit_env_file, path_fields: PATH_FIELDS,
          env_path_keys: %w[VXLAN_DIRECTORY NC_KNOWN_HOSTS ND_CACHE_DIRECTORY ND_DB_SSLROOTCERT],
          path_literals: { "netdisco.db_sslrootcert" => [ "system" ], "ND_DB_SSLROOTCERT" => [ "system" ] }, **@discovery)
        @files.load_environment(allow_missing: flags[:init])
        @environment = @files.environment
        @config, @env_file = @files.config, @files.env_file
      rescue LoadError
        raise LoadError, "采集配置需要 net-connector >= 0.17.0；读取 .env 还需要 dotenv", cause: nil
      end

      # 公共与专用文件先合并，进程值和 CLI 最后覆盖；数组不追加设备。
      def load
        @files.load
        @config, @env_file = @files.config, @files.env_file
        data = Net::Connector::Config.merge(@files.data)
        raise ArgumentError, "YAML 只接受公开配置字段" unless (data.keys - FIELDS).empty?
        specific = @files.specific
        if specific["devices"].is_a?(Array) && specific["devices"].any? && (specific.keys & %w[netdisco inventory netdisco_config]).empty?
          data = data.except("netdisco", "inventory")
        elsif specific["netdisco_config"] && (specific.keys & %w[netdisco inventory]).empty?
          data = data.except("netdisco", "inventory")
        end
        defaults = { "fabric" => "default", "devices" => [], "parallel" => 4, "directory" => @directory,
          "dimensions" => Vxlan::Collector::COMMANDS.keys.map(&:to_s), "ssh" => SSH_DEFAULTS }
        dynamic = (data.keys & %w[netdisco inventory]).any?
        process = environment_values(@files.process_environment, dynamic: dynamic)
        file_defaults = environment_values(@files.file_environment, dynamic: dynamic,
          higher: Net::Connector::Config.merge(data, process, @overrides))
        @values = Net::Connector::Config.merge(defaults, file_defaults, data, process, @overrides)
        validate!
        netdisco_settings if dynamic_inventory?
        @fabric_policy = nil
        if values["fabric_policy"]
          raise ArgumentError, "fabric_policy 须为路径" unless values["fabric_policy"].is_a?(String)
          policy = YAML.safe_load(File.read(values["fabric_policy"]), aliases: false)
          Vxlan::Fabric::Scope.new(policy)
          @fabric_policy = CtxParser::Immutable.copy(policy)
        end
        self
      rescue Psych::Exception
        raise ArgumentError, "YAML 无效或包含不允许的类型", cause: nil
      end

      # 对外只列来源路径和字段归属，不携带环境文件的值。
      def sources = @files.sources

      # 来源选择与默认参数分开；共同 Netdisco 配置不会改写显式静态清单。
      def dynamic_inventory? = values["netdisco_config"] || values.key?("netdisco") || values.key?("inventory")

      # 凭据使用本批有效环境，公共环境值按相同优先级交给原生 Settings。
      def netdisco_settings
        return @netdisco_settings if @netdisco_settings
        require "net/connector/netdisco"
        schema = Net::Connector::Netdisco::Config
        sections = %w[netdisco inventory]
        data = values["netdisco_config"] ? external_inventory_data : values.slice(*sections)
        document = schema.parse_sections(data, sections: sections)
        keys = schema.environment_keys
        inventory_keys = schema.environment_keys(sections: sections)
        defaults = @files.file_environment.slice(*inventory_keys).merge(document)
        process = @files.process_environment.slice(*inventory_keys)
        secrets = environment.reject { |key, _| keys.include?(key) || key == "NC_CONFIG" }
        @inventory_public = schema.from_environment(defaults.merge(process), sections: sections)
        @netdisco_settings = Net::Connector::Netdisco::Settings.new(env: secrets, defaults: defaults, overrides: process).for_run(mode: :inventory)
      end

      # 外部清单同样按文件来源解析路径，并在预检时固定本批配置。
      def external_inventory_data
        Net::Connector::Config.new(name: "backup", env: {}, directories: [], config: values.fetch("netdisco_config"),
          path_fields: %w[netdisco.cache_directory netdisco.db_sslrootcert],
          path_literals: { "netdisco.db_sslrootcert" => [ "system" ] }).load.data
      end
      private :external_inventory_data

      # 展示外部清单的有效公开字段，预览与执行共用本批快照。
      def public_values
        return values unless values["netdisco_config"]
        netdisco_settings
        values.merge("inventory_configuration" => @inventory_public)
      end

      # 只初始化缺失文件，排他创建防止覆盖现场配置；不读取设备清单。
      def initialize_files
        template = File.read(File.join(__dir__, "templates/vxlan.yml"))
        @config, @env_file = @files.init_config, @files.init_env_file
        @values = Net::Connector::Config.merge(YAML.safe_load(template), { "directory" => @directory, "parallel" => 4 },
          environment_values(@files.file_environment), environment_values(@files.process_environment), @overrides)
        validate!
        # 公共 NC_PARALLEL 保持继承；只有本工具显式覆盖才写入 YAML。
        parallel_source = [ @files.process_environment, @files.file_environment ].find do |source|
          source["VXLAN_PARALLEL"] || source["NC_PARALLEL"]
        end
        overrides_parallel = @overrides.key?("parallel") || parallel_source&.fetch("VXLAN_PARALLEL", nil)
        document = overrides_parallel ? values : values.reject { |key, _| key == "parallel" }
        template = template.lines.select { |line| line.start_with?("#") }.join +
          Net::Connector::Config.dump(document, name: "vxlan", path: config)
        { config => template, env_file => File.read(File.join(__dir__, "templates/env.example")) }.each do |path, body|
          FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
          begin
            Tempfile.create([ ".vxlan-init-", ".tmp" ], File.dirname(path)) do |file|
              file.chmod(0o600)
              file.write(body)
              file.flush
              file.fsync
              File.link(file.path, path)
            end
            @out.puts "已创建：#{path}"
          rescue Errno::EEXIST
            @out.puts "已保留：#{path}"
          end
        end
        @out.puts "请检查配置及凭据后再次运行；本次未读取清单、未连接设备。"
      end

      # 默认仅在真实终端提供初始化选择；自动化从不消费 stdin。
      def missing?(input:, error:)
        @files.load
        @config, @env_file = @files.config, @files.env_file
        return false unless @files.missing?
        if input.tty? && error.tty? && flags[:interactive] != false
          error.print "配置不存在：#{config}；是否创建配置与环境模板？[y/N] "
          error.flush
          if input.gets&.strip&.match?(/\Ay(?:es)?\z/i)
            initialize_files
            return true
          end
        end
        raise ArgumentError, "配置不存在：#{config}；请执行 --init 后填写设备，或使用 --config 指定配置"
      end

      # 公开配置输出与实际清单复用身份预检，不读取远端清单。
      def normalize_devices(rows)
        raise ArgumentError, "devices 须为数组" unless rows.is_a?(Array)
        targets = rows.map { |row| normalize_device(row) }
        raise ArgumentError, "设备清单包含重复管理地址" unless targets.map { |row| row.fetch("host") }.uniq.size == targets.size
        targets
      end

      private

      # 环境值只映射公开字段；非法低优先级值可以被更高层覆盖，最终统一校验。
      def environment_values(source, dynamic: false, higher: {})
        result = {}
        { "VXLAN_FABRIC" => "fabric", "VXLAN_DIRECTORY" => "directory" }.each do |key, field|
          result[field] = source[key] if source.key?(key)
        end
        parallel = source["VXLAN_PARALLEL"] || source["NC_PARALLEL"]
        result["parallel"] = Integer(parallel, exception: false) || parallel if parallel
        ssh = {}
        { "NC_HOST_KEY_POLICY" => "host_key_policy", "NC_KNOWN_HOSTS" => "known_hosts" }.each do |key, field|
          ssh[field] = source[key] if source.key?(key)
        end
        result["ssh"] = ssh if ssh.any?
        if dynamic
          require "net/connector/netdisco/config"
          result.merge!(Net::Connector::Netdisco::Config.from_environment(source, sections: %w[netdisco inventory], higher: higher))
        end
        result
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

      # 显式声明短参数与长参数；不提供难以发现的兼容缩写。
      def parser
        OptionParser.new do |p|
          p.banner = "用法：#{@command} [选项]（只读 VXLAN 采集）"
          p.on("--config FILE", "最高优先级 YAML，叠加系统/用户/脚本/工作目录配置") { |v| @explicit_config = File.expand_path(v) }
          p.on("--env-file FILE", "最高优先级环境文件；进程环境仍优先") { |v| @explicit_env_file = File.expand_path(v) }
          p.on("-p", "--parallel N", Integer, "设备并发 1～500；继承 NC_PARALLEL，未配置时 4") { |v| @overrides["parallel"] = v }
          p.on("--directory DIR", "按设备保存报告的目录") { |v| @overrides["directory"] = File.expand_path(v) }
          p.on("--fabric-policy FILE", "显式 Fabric/Leaf/Border/Spine 清单 YAML") { |v| @overrides["fabric_policy"] = File.expand_path(v) }
          p.on("--fabric NAME", "采集所属 Fabric 身份") { |v| @overrides["fabric"] = v }
          p.on("--dimensions LIST", "逗号分隔维度；--help 查看支持项") { |v| @overrides["dimensions"] = list(v) }
          Net::Connector::Inventory::Filters.add_options(p) do |key, value|
            if value.is_a?(Array)
              (@overrides[key] ||= []).concat(value)
            else
              @overrides[key] = value
            end
          end
          p.on("--init", "创建缺失配置和环境模板后退出；已有文件不覆盖") { flags[:init] = true }
          p.on("--interactive", "缺少配置时询问是否创建；要求真实终端") { flags[:interactive] = true }
          p.on("--non-interactive", "禁用问答；创建文件须同时指定 --init") { flags[:interactive] = false }
          p.on("--plan", "--inventory-only", "预览筛选清单，不连接设备") { flags[:inventory_only] = true }
          p.on("--show-config", "查看公开有效配置") { flags[:show_config] = true }
          p.on("--json", "stdout 输出 JSON；默认显示可读摘要") { flags[:json] = true }
          p.on("--quiet", "--no-progress", "关闭 stderr 进度，可配合 --json") { flags[:quiet] = true }
          p.on("--[no-]scripts", "可选导出配置建议，默认仅诊断") { |value| flags[:scripts] = value }
          p.on("--verbose", "显示逐台结果及安全命令事件") { flags[:verbose] = true }
          p.on("-h", "--help", "查看选项帮助") { flags[:help] = true }
          p.on("--help-all", "查看全部选项、路径与环境约定") { flags[:help_all] = true }
          p.on("--examples", "查看常用命令范例，不执行任务") { flags[:examples] = true }
          p.separator "维度：#{Vxlan::Collector::COMMANDS.keys.join(', ')}"
          p.separator "优先级：CLI > 进程环境 > YAML > .env > 内置默认值。退出码：0 完整/预览；1 未完成/无目标；2 参数/持久化错误；130 取消。"
        end
      end

      # 列表中的空项属于输入错误，不能被静默删掉。
      def list(value)
        values = value.split(",", -1).map(&:strip)
        raise ArgumentError, "列表不能有空项" if values.any?(&:empty?)
        values
      end

      # 先验证整批策略，避免在前面设备连接后才发现后面的非法配置。
      def validate!
        raise ArgumentError, "parallel 须为 1～500" unless values["parallel"].is_a?(Integer) && (1..500).cover?(values["parallel"])
        %w[fabric directory].each { |key| raise ArgumentError, "#{key} 须为非空字符串" unless values[key].is_a?(String) && !values[key].strip.empty? }
        dimensions = values["dimensions"]
        unless dimensions.is_a?(Array) && dimensions.any? && dimensions.all?(String) && dimensions.uniq == dimensions && (dimensions - Vxlan::Collector::COMMANDS.keys.map(&:to_s)).empty?
          raise ArgumentError, "dimensions 包含未知、重复或空维度"
        end
        values["devices"] = normalize_devices(values["devices"])
        inline = %w[netdisco inventory].any? { |key| values.key?(key) }
        %w[netdisco inventory].each do |key|
          raise ArgumentError, "#{key} 须为映射" if values.key?(key) && !values[key].is_a?(Hash)
        end
        if inline && (!values["devices"].empty? || values["netdisco_config"])
          raise ArgumentError, "静态 devices、内嵌 Netdisco 和外部 netdisco_config 不能同时声明"
        end
        if values["netdisco_config"]
          raise ArgumentError, "netdisco_config 须为配置路径，且不能同时声明 devices" unless values["netdisco_config"].is_a?(String) && !values["netdisco_config"].empty? && values["devices"].empty?
          values["netdisco_config"] = File.expand_path(values["netdisco_config"], Dir.pwd)
        end
        Net::Connector::Inventory::Filters::LISTS.each_key { |key| values[key] = values.fetch(key, []) }
        Net::Connector::Inventory::Filters.selection(values)
        ssh = values["ssh"]
        raise ArgumentError, "ssh 包含未知或敏感字段" unless ssh.is_a?(Hash) && (ssh.keys - SSH_FIELDS).empty?
        ssh = SSH_DEFAULTS.merge(ssh)
        raise ArgumentError, "host_key_policy 须为 strict 或 accept_new" unless %w[strict accept_new].include?(ssh["host_key_policy"])
        %w[command_timeout login_timeout].each { |key| raise ArgumentError, "#{key} 须为正数" unless ssh[key].is_a?(Numeric) && ssh[key].finite? && ssh[key].positive? }
        raise ArgumentError, "port 须为 1～65535" if ssh.key?("port") && (!ssh["port"].is_a?(Integer) || !(1..65535).cover?(ssh["port"]))
        if ssh.key?("known_hosts")
          raise ArgumentError, "known_hosts 须为路径" unless ssh["known_hosts"].is_a?(String) && !ssh["known_hosts"].empty?
          ssh["known_hosts"] = File.expand_path(ssh["known_hosts"], Dir.pwd)
        end
        values["ssh"] = ssh
        values["directory"] = File.expand_path(values["directory"], Dir.pwd)
      rescue IPAddr::Error
        raise ArgumentError, "hosts 须为 IP 或 CIDR，不展开地址、不扫描网段", cause: nil
      end
    end
  end
end
