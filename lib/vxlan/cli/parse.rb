# frozen_string_literal: true

require "ctx_cli/command"
require "ctx_cli/options"
require "ctx_cli/input"
require "ctx_cli/output"
require "json"
require "time"
require "vxlan"

module Vxlan
  module CLI
    # 离线解析显式提供的文件或 stdin，不自行假定传输完整。
    class Parse
      # 注入标准流，便于在宿主测试中验证无需网络的行为。
      def initialize(out: $stdout, error: $stderr, input: $stdin, command: "vxlan parse")
        @out, @error, @input, @command = out, error, input, command
        @output = CtxCli::Output.new(out: out, error: error)
      end

      # 参数错误与部分证据分开返回；默认只显示元数据，JSON 显式导出事实。
      def run(argv)
        command = CtxCli::Command.new(banner: "Usage: #{@command} [options] (offline file or stdin)", defaults: { dimension: :configuration, complete: false }, out: @out) do |p, options|
          p.on("--file FILE", "Read a file; defaults to stdin") { |v| options[:file] = v }
          p.on("--dimension NAME", "configuration or a runtime dimension") { |v| options[:dimension] = v.to_sym }
          p.on("--model NAME", "Device model") { |v| options[:model] = v }
          p.on("--complete", "Declare input fully collected; missing parse evidence is still reported") { options[:complete] = true }
          p.on("--json", "Output facts as JSON; may contain sensitive configuration") { options[:json] = true }
          CtxCli::Options.information(p, options)
          p.separator "Dimensions: #{Vxlan::Collector::COMMANDS.keys.join(', ')}"
        end
        options = command.parse(argv)
        return 0 if command.informational?(examples: "#{@command} --file running.cfg --complete\ncat nve.txt | #{@command} --dimension nve_peers --complete --json")
        raise ArgumentError, "Unknown dimension" unless Vxlan::Collector::COMMANDS.key?(options[:dimension])

        body = CtxCli::Input.read(path: options[:file], input: @input)
        observation = if options[:dimension] == :configuration
          Vxlan::Config.new(model: options[:model]).parse(body, complete: options[:complete])
        else
          Vxlan::RuntimeParser.new(platform: :cisco_nxos, model: options[:model]).parse(options[:dimension], body, complete: options[:complete])
        end
        if options[:json]
          @output.json(observation.to_h)
        else
          @out.puts "Dimensions: #{observation.name}; evidence: #{observation.status}; records: #{observation.records.size}"
          @out.puts "Diagnostics: #{observation.issues.map { |issue| issue[:code] }.uniq.join(', ')}" unless observation.issues.empty?
          @out.puts "Complete evidence does not establish Fabric health."
        end
        observation.complete? ? 0 : 1
      rescue OptionParser::ParseError, ArgumentError, SystemCallError, IOError => error
        @output.diagnostic("Offline parsing argument or file error; use --help for options", exception: error)
        2
      end
    end
  end
end
