# frozen_string_literal: true

require "optparse"
require "yaml"
require "ipaddr"
require "fileutils"
require "tempfile"

module Vxlan
  module CLI
    # 采集入口的公开参数；凭据始终留在环境中，不传入解析库或 YAML。
    class Options
      FIELDS = %w[fabric devices netdisco_config parallel directory dimensions ssh hosts exclude_hosts names exclude_names].freeze
      SSH_FIELDS = %w[port command_timeout login_timeout host_key_policy known_hosts].freeze
      attr_reader :values, :config, :env_file, :flags

      # 固定入口路径，显式参数按启动目录解析，YAML 路径相对配置目录或调用方指定基准。
      def initialize(argv, env:, out:, config: File.join(Dir.pwd, "vxlan.yml"), env_file: File.join(Dir.pwd, ".env"), directory: File.join(Dir.pwd, "vxlans"), base: nil, command: "vxlan collect")
        @env, @out = env, out
        @base, @directory, @command = base, directory, command
        selected = env["VXLAN_CONFIG"]
        @explicit_config = selected && !selected.strip.empty?
        @config = File.expand_path(@explicit_config ? selected : config)
        @env_file = env_file
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
            @out.puts "进程环境优先于 .env；YAML 相对路径基于配置目录，CLI 路径基于启动目录。默认报告：#{@directory}"
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

      # 先读取环境默认，再由 YAML 和显式命令行覆盖；不把密码合入公开配置。
      def load_environment
        if File.file?(env_file)
          require "dotenv"
          Dotenv.parse(env_file).each { |key, value| @env[key] = value unless @env.key?(key) }
        end
        @config = File.expand_path(@env["VXLAN_CONFIG"], @base || Dir.pwd) if !@explicit_config && @env["VXLAN_CONFIG"] && !@env["VXLAN_CONFIG"].strip.empty?
      rescue LoadError
        raise LoadError, "读取环境文件需要 dotenv；请 gem install dotenv 或在宿主 Gemfile 添加依赖", cause: nil
      end

      # 将已经加载的环境默认与无凭据 YAML、命令行逐层合并。
      def load
        data = YAML.safe_load(File.read(config), permitted_classes: [], permitted_symbols: [], aliases: false)
        raise ArgumentError, "YAML 须为映射，且只接受公开配置字段" unless data.is_a?(Hash) && (data.keys - FIELDS).empty?

        defaults = { "fabric" => @env.fetch("VXLAN_FABRIC", "default"), "devices" => [],
          "parallel" => @env.fetch("VXLAN_PARALLEL", @env.fetch("NC_PARALLEL", "4")),
          "directory" => File.expand_path(@env.fetch("VXLAN_DIRECTORY", @directory), @base || Dir.pwd), "dimensions" => Vxlan::Collector::COMMANDS.keys.map(&:to_s),
          "ssh" => { "host_key_policy" => "strict", "command_timeout" => 60, "login_timeout" => 15 } }
        @values = defaults.merge(data).merge(@overrides)
        unless data.key?("parallel") || @overrides.key?("parallel")
          raise ArgumentError, "环境并发数须为整数" unless values["parallel"].match?(/\A[0-9]+\z/)
          values["parallel"] = Integer(values["parallel"], 10)
        end
        validate!
        self
      rescue Psych::Exception
        raise ArgumentError, "YAML 无效或包含不允许的类型", cause: nil
      end

      # 只初始化缺失文件，排他创建防止覆盖现场配置；不读取设备清单。
      def initialize_files
        template = File.read(File.join(__dir__, "templates/vxlan.yml"))
        public_defaults = { "directory" => @directory }
        { "VXLAN_FABRIC" => "fabric", "VXLAN_DIRECTORY" => "directory" }.each do |key, field|
          public_defaults[field] = (field == "directory" ? File.expand_path(@env[key], @base || Dir.pwd) : @env[key]) if @env.key?(key)
        end
        parallel = @env["VXLAN_PARALLEL"] || @env["NC_PARALLEL"]
        if parallel && !@overrides.key?("parallel")
          raise ArgumentError, "环境并发数须为整数" unless parallel.match?(/\A[0-9]+\z/)
          public_defaults["parallel"] = Integer(parallel, 10)
        end
        @values = YAML.safe_load(template).merge(public_defaults).merge(@overrides)
        validate!
        template = template.lines.select { |line| line.start_with?("#") }.join + YAML.dump(values)
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
        return false if File.file?(config)
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

      private

      # 显式声明短参数与长参数；不提供难以发现的兼容缩写。
      def parser
        OptionParser.new do |p|
          p.banner = "用法：#{@command} [选项]（只读 VXLAN 采集）"
          p.on("--config FILE", "配置 YAML，默认 #{@config}") { |v| @config = File.expand_path(v); @explicit_config = true }
          p.on("--env-file FILE", "环境文件，默认 #{@env_file}") { |v| @env_file = File.expand_path(v) }
          p.on("-p", "--parallel N", Integer, "设备并发 1～500，默认 4") { |v| @overrides["parallel"] = v }
          p.on("--directory DIR", "按设备保存报告的目录") { |v| @overrides["directory"] = File.expand_path(v) }
          p.on("--fabric NAME", "采集所属 Fabric 身份") { |v| @overrides["fabric"] = v }
          p.on("--dimensions LIST", "逗号分隔维度；--help 查看支持项") { |v| @overrides["dimensions"] = list(v) }
          { "--host IP" => "hosts", "--hosts LIST" => "hosts", "--exclude-hosts LIST" => "exclude_hosts",
            "--name LIST" => "names", "--exclude-name LIST" => "exclude_names" }.each do |option, key|
            p.on(option, "筛选已有清单，同类条件取并集，排除优先") { |v| (@overrides[key] ||= []).concat(list(v)) }
          end
          p.on("--init", "创建缺失配置和环境模板后退出；已有文件不覆盖") { flags[:init] = true }
          p.on("--interactive", "缺少配置时询问是否创建；要求真实终端") { flags[:interactive] = true }
          p.on("--non-interactive", "禁用问答；创建文件须同时指定 --init") { flags[:interactive] = false }
          p.on("--plan", "--inventory-only", "预览筛选清单，不连接设备") { flags[:inventory_only] = true }
          p.on("--show-config", "查看公开有效配置") { flags[:show_config] = true }
          p.on("--json", "stdout 输出 JSON；默认显示可读摘要") { flags[:json] = true }
          p.on("--quiet", "--no-progress", "关闭 stderr 进度，可配合 --json") { flags[:quiet] = true }
          p.on("--verbose", "显示逐台结果") { flags[:verbose] = true }
          p.on("-h", "--help", "查看选项帮助") { flags[:help] = true }
          p.on("--help-all", "查看全部选项、路径与环境约定") { flags[:help_all] = true }
          p.on("--examples", "查看常用命令范例，不执行任务") { flags[:examples] = true }
          p.separator "维度：#{Vxlan::Collector::COMMANDS.keys.join(', ')}"
          p.separator "优先级：CLI > YAML > 环境默认值。退出码：0 完整/预览；1 未完成/无目标；2 参数/持久化错误；130 取消。"
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
        raise ArgumentError, "devices 须为数组" unless values["devices"].is_a?(Array)
        if values["netdisco_config"]
          raise ArgumentError, "netdisco_config 须为配置路径，且不能同时声明 devices" unless values["netdisco_config"].is_a?(String) && !values["netdisco_config"].empty? && values["devices"].empty?
          values["netdisco_config"] = File.expand_path(values["netdisco_config"], @base || File.dirname(config))
        end
        %w[hosts exclude_hosts names exclude_names].each do |key|
          items = values[key] ||= []
          raise ArgumentError, "#{key} 须为非空字符串数组" unless items.is_a?(Array) && items.all? { |v| v.is_a?(String) && !v.strip.empty? }
        end
        %w[hosts exclude_hosts].each { |key| values[key].each { |v| IPAddr.new(v) } }
        ssh = values["ssh"]
        raise ArgumentError, "ssh 包含未知或敏感字段" unless ssh.is_a?(Hash) && (ssh.keys - SSH_FIELDS).empty?
        ssh = { "host_key_policy" => "strict", "command_timeout" => 60, "login_timeout" => 15 }.merge(ssh)
        raise ArgumentError, "host_key_policy 须为 strict 或 accept_new" unless %w[strict accept_new].include?(ssh["host_key_policy"])
        %w[command_timeout login_timeout].each { |key| raise ArgumentError, "#{key} 须为正数" unless ssh[key].is_a?(Numeric) && ssh[key].finite? && ssh[key].positive? }
        raise ArgumentError, "port 须为 1～65535" if ssh.key?("port") && (!ssh["port"].is_a?(Integer) || !(1..65535).cover?(ssh["port"]))
        if ssh.key?("known_hosts")
          raise ArgumentError, "known_hosts 须为路径" unless ssh["known_hosts"].is_a?(String) && !ssh["known_hosts"].empty?
          ssh["known_hosts"] = File.expand_path(ssh["known_hosts"], @base || File.dirname(config))
        end
        values["ssh"] = ssh
        values["directory"] = File.expand_path(values["directory"], @base || File.dirname(config))
      rescue IPAddr::Error
        raise ArgumentError, "hosts 须为 IP 或 CIDR，不展开地址、不扫描网段", cause: nil
      end
    end
  end
end
