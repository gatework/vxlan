# frozen_string_literal: true

require "vxlan/version"
require "ctx_cli/router"

module Vxlan
  # 命令入口按需加载采集或解析实现；核心库无需加载 CLI。
  module CLI
    # 由调用方拥有退出行为，库入口只返回退出码。
    def self.run(argv, env: ENV, out: $stdout, error: $stderr, input: $stdin, **collect_options)
      commands = {
        "collect" => ->(arguments) do
          begin
            require_relative "cli/collect"
          rescue LoadError
            error.puts "collect requires a current net-connector with shared inventory filters; install the project dependencies."
            next 2
          end
          Collect.new(env: env, out: out, error: error, input: input, **collect_options).run(arguments)
        end,
        "apply" => ->(arguments) do
          require_relative "cli/apply"
          Apply.new(env: env, out: out, error: error, input: input, connector_factory: collect_options[:connector_factory], discovery: collect_options.fetch(:discovery, {})).run(arguments)
        end,
        "review" => ->(arguments) do
          require_relative "cli/review"
          Review.new(out: out, error: error).run(arguments)
        end,
        "parse" => ->(arguments) do
          require_relative "cli/parse"
          Parse.new(out: out, error: error, input: input, command: collect_options.fetch(:command, "vxlan parse")).run(arguments)
        end
      }
      CtxCli::Router.new(name: "vxlan", version: Vxlan::VERSION, usage: USAGE,
        commands: commands, out: out, error: error).run(argv)
    end

    # 全局帮助不读取配置、环境文件或设备清单。
    USAGE = "Usage: vxlan collect [options]  Read-only collection and reports\n       vxlan parse [options]    Parse offline files or stdin\n       vxlan review --batch DIR  Offline remediation recommendations\n       vxlan apply --plan FILE --item ID  Apply after interactive confirmation\n       vxlan --version\nUse vxlan collect --help, vxlan parse --help or vxlan review --help for options; --help-all for full conventions, --examples for examples.".freeze
    private_constant :USAGE
  end
end
