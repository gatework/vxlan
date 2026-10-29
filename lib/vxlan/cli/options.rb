# frozen_string_literal: true

require "ctx_cli/collection"
require "ctx_cli/input"
require "optparse"
require "ctx_cli/options"
require "ctx_cli/terminal"
require "ctx_cli/initializer"
gem "net-connector", "~> 0.20.0"
require "net/connector/inventory/filters"
require "yaml"
require "ipaddr"

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
        @parser.parse!(argv.dup).tap { |rest| raise ArgumentError, "Positional arguments are not accepted" unless rest.empty? }
      end

      # 帮助和范例只打印文本，不读取文件或加载可选网络依赖。
      def informational?
        if flags[:help] || flags[:help_all]
          @out.puts @parser
          if flags[:help_all]
            @out.puts "Environment defaults: VXLAN_CONFIG, VXLAN_FABRIC, VXLAN_PARALLEL (or NC_PARALLEL), VXLAN_DIRECTORY."
            @out.puts "Credentials: NC_DEVICE_USERNAME / NC_DEVICE_PASSWORD, or NC_CISCO_NXOS_USERNAME / NC_CISCO_NXOS_PASSWORD; optional NC_ENABLE_PASSWORD."
            @out.puts "Precedence: CLI > process environment > YAML > .env > built-in defaults. YAML/.env paths are relative to their source directory; CLI paths are relative to the startup directory. Default reports: #{@directory}"
          end
        elsif flags[:examples]
          @out.puts "Common examples (replace addresses with actual inventory addresses):\n  Initialize missing files and exit:\n    #{@command} --init --non-interactive\n  Preview filtered inventory:\n    #{@command} --host 192.0.2.10 --plan\n  Select devices by name:\n    #{@command} --name leaf --exclude-name spare -p 4\n  Automated collection summary:\n    #{@command} --dimensions configuration,nve_peers --json --no-progress"
        else
          return false
        end
        true
      end

      # 自动化拒绝强制问答；帮助分支无需检查终端或消费输入。
      def validate_interaction!(input:, error:)
        if flags[:interactive] && !CtxCli::Terminal.tty?(input, error)
          raise CtxCli::Collection::Error, "--interactive requires an interactive terminal; use --init --non-interactive for automation"
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
        raise LoadError, "Collection configuration requires net-connector >= 0.20.0; reading .env also requires dotenv", cause: nil
      end

      # 公共与专用文件先合并，进程值和 CLI 最后覆盖；数组不追加设备。
      def load
        @files.load
        @config, @env_file = @files.config, @files.env_file
        data = Net::Connector::Config.merge(@files.data)
        raise ArgumentError, "YAML accepts only public configuration fields" unless (data.keys - FIELDS).empty?
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
          raise ArgumentError, "fabric_policy must be a path" unless values["fabric_policy"].is_a?(String)
          policy = YAML.safe_load(CtxCli::Input.read(path: values["fabric_policy"]), aliases: false)
          Vxlan::Fabric::Scope.new(policy)
          @fabric_policy = CtxParser::Immutable.copy(policy)
        end
        self
      rescue Psych::Exception
        raise ArgumentError, "Invalid YAML or disallowed types", cause: nil
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
        template = template.lines("\n").select { |line| line.start_with?("#") }.join("") +
          Net::Connector::Config.dump(document, name: "vxlan", path: config)
        { config => template, env_file => File.read(File.join(__dir__, "templates/env.example")) }.each do |path, body|
          status = CtxCli::Initializer.new(prefix: ".vxlan-init-").create(path: path, contents: body)
          @out.puts "#{status == :created ? 'created' : 'preserved'}: #{path}"
        end
        @out.puts "Check configuration and credentials, then run again; inventory was not read and no devices were connected."
      end

      # 默认仅在真实终端提供初始化选择；自动化从不消费 stdin。
      def missing?(input:, error:)
        @files.load
        @config, @env_file = @files.config, @files.env_file
        return false unless @files.missing?
        terminal = CtxCli::Terminal.new(input: input, out: error)
        if terminal.tty? && flags[:interactive] != false
          answer = terminal.question("Configuration does not exist: #{config}; create configuration and environment templates? [y/N] ")
          if answer&.match?(/\Ay(?:es)?\z/i)
            initialize_files
            return true
          end
        end
        raise ArgumentError, "Configuration does not exist: #{config}; run --init and fill in devices, or select configuration with --config"
      end

      # 公开配置输出与实际清单复用身份预检，不读取远端清单。
      def normalize_devices(rows)
        raise ArgumentError, "devices must be an array" unless rows.is_a?(Array)
        targets = rows.map { |row| normalize_device(row) }
        raise ArgumentError, "Device inventory contains duplicate management addresses" unless targets.map { |row| row.fetch("host") }.uniq.size == targets.size
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
          raise ArgumentError, "devices accepts only host, name and model; host must be a single IP address"
        end
        host = IPAddr.new(row.fetch("host")).to_s
        %w[name model].each { |key| raise ArgumentError, "Device #{key} must be a nonempty string" if row.key?(key) && !row[key].nil? && (!row[key].is_a?(String) || row[key].strip.empty?) }
        { "host" => host, "name" => row["name"] || host, "model" => row["model"] }.freeze
      rescue IPAddr::Error
        raise ArgumentError, "Invalid device host", cause: nil
      end

      # 显式声明短参数与长参数；不提供难以发现的兼容缩写。
      def parser
        OptionParser.new do |p|
          p.banner = "Usage: #{@command} [options] (read-only VXLAN collection)"
          CtxCli::Options.configuration(p, parallel_help: "Device concurrency 1 to 500; inherits NC_PARALLEL, defaults to 4") do |key, value|
            case key
            when :config then @explicit_config = File.expand_path(value, Dir.pwd)
            when :env_file then @explicit_env_file = File.expand_path(value, Dir.pwd)
            when :directory then @overrides["directory"] = File.expand_path(value, Dir.pwd)
            when :parallel then @overrides["parallel"] = value
            end
          end
          p.on("--fabric-policy FILE", "Explicit Fabric/Leaf/Border/Spine inventory YAML") { |v| @overrides["fabric_policy"] = File.expand_path(v) }
          p.on("--fabric NAME", "Fabric identity for this collection") { |v| @overrides["fabric"] = v }
          p.on("--dimensions LIST", "Comma-separated dimensions; see --help for supported values") { |v| @overrides["dimensions"] = list(v) }
          Net::Connector::Inventory::Filters.add_options(p) do |key, value|
            if value.is_a?(Array)
              (@overrides[key] ||= []).concat(value)
            else
              @overrides[key] = value
            end
          end
          CtxCli::Options.initialization(p, flags)
          p.on("--plan", "--inventory-only", "Preview filtered inventory without connecting to devices") { flags[:inventory_only] = true }
          p.on("--show-config", "Show effective public configuration") { flags[:show_config] = true }
          CtxCli::Options.output(p, flags)
          p.on("--[no-]scripts", "Optionally export configuration suggestions; diagnostics only by default") { |value| flags[:scripts] = value }
          CtxCli::Options.information(p, flags)
          p.separator "Dimensions: #{Vxlan::Collector::COMMANDS.keys.join(', ')}"
          p.separator "Precedence: CLI > process environment > YAML > .env > built-in defaults. Exit codes: 0 complete/preview; 1 incomplete/no targets; 2 argument/persistence error; 130 cancelled."
        end
      end

      # 列表中的空项属于输入错误，不能被静默删掉。
      def list(value) = CtxCli::Options.list(value)

      # 先验证整批策略，避免在前面设备连接后才发现后面的非法配置。
      def validate!
        raise ArgumentError, "parallel must be 1 to 500" unless values["parallel"].is_a?(Integer) && (1..500).cover?(values["parallel"])
        %w[fabric directory].each { |key| raise ArgumentError, "#{key} must be a nonempty string" unless values[key].is_a?(String) && !values[key].strip.empty? }
        dimensions = values["dimensions"]
        unless dimensions.is_a?(Array) && dimensions.any? && dimensions.all?(String) && dimensions.uniq == dimensions && (dimensions - Vxlan::Collector::COMMANDS.keys.map(&:to_s)).empty?
          raise ArgumentError, "dimensions contains unknown, duplicate or empty dimensions"
        end
        values["devices"] = normalize_devices(values["devices"])
        inline = %w[netdisco inventory].any? { |key| values.key?(key) }
        %w[netdisco inventory].each do |key|
          raise ArgumentError, "#{key} must be a mapping" if values.key?(key) && !values[key].is_a?(Hash)
        end
        if inline && (!values["devices"].empty? || values["netdisco_config"])
          raise ArgumentError, "Static devices, inline Netdisco and external netdisco_config are mutually exclusive"
        end
        if values["netdisco_config"]
          raise ArgumentError, "netdisco_config must be a configuration path and cannot be combined with devices" unless values["netdisco_config"].is_a?(String) && !values["netdisco_config"].empty? && values["devices"].empty?
          values["netdisco_config"] = File.expand_path(values["netdisco_config"], Dir.pwd)
        end
        Net::Connector::Inventory::Filters::LISTS.each_key { |key| values[key] = values.fetch(key, []) }
        Net::Connector::Inventory::Filters.selection(values)
        ssh = values["ssh"]
        raise ArgumentError, "ssh contains unknown or sensitive fields" unless ssh.is_a?(Hash) && (ssh.keys - SSH_FIELDS).empty?
        ssh = SSH_DEFAULTS.merge(ssh)
        raise ArgumentError, "host_key_policy must be strict or accept_new" unless %w[strict accept_new].include?(ssh["host_key_policy"])
        %w[command_timeout login_timeout].each { |key| raise ArgumentError, "#{key} must be positive" unless ssh[key].is_a?(Numeric) && ssh[key].finite? && ssh[key].positive? }
        raise ArgumentError, "port must be 1 to 65535" if ssh.key?("port") && (!ssh["port"].is_a?(Integer) || !(1..65535).cover?(ssh["port"]))
        if ssh.key?("known_hosts")
          raise ArgumentError, "known_hosts must be a path" unless ssh["known_hosts"].is_a?(String) && !ssh["known_hosts"].empty?
          ssh["known_hosts"] = File.expand_path(ssh["known_hosts"], Dir.pwd)
        end
        values["ssh"] = ssh
        values["directory"] = File.expand_path(values["directory"], Dir.pwd)
      rescue IPAddr::Error
        raise ArgumentError, "hosts must contain IPs or CIDRs; addresses are not expanded and subnets are not scanned", cause: nil
      end
    end
  end
end
