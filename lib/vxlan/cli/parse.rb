# frozen_string_literal: true

require "optparse"
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
      end

      # 参数错误与部分证据分开返回；默认只显示元数据，JSON 显式导出事实。
      def run(argv)
        options = { dimension: :configuration, complete: false }
        parser = OptionParser.new do |p|
          p.banner = "用法：#{@command} [选项]（离线文件或 stdin）"
          p.on("--file FILE", "读取文件，默认 stdin") { |v| options[:file] = v }
          p.on("--dimension NAME", "configuration 或运行维度") { |v| options[:dimension] = v.to_sym }
          p.on("--model NAME", "设备型号") { |v| options[:model] = v }
          p.on("--complete", "声明输入已完整采集，仍保留解析缺失诊断") { options[:complete] = true }
          p.on("--json", "输出事实 JSON，可能包含配置敏感信息") { options[:json] = true }
          p.on("-h", "--help", "查看帮助") { options[:help] = true }
          p.on("--help-all", "查看全部选项") { options[:help] = true }
          p.on("--examples", "查看示例") { options[:examples] = true }
          p.separator "维度：#{Vxlan::Collector::COMMANDS.keys.join(', ')}"
        end
        rest = parser.parse(argv.dup)
        raise ArgumentError, "不接受位置参数" unless rest.empty?
        return @out.puts(parser) || 0 if options[:help]
        return @out.puts("#{@command} --file running.cfg --complete\ncat nve.txt | #{@command} --dimension nve_peers --complete --json") || 0 if options[:examples]
        raise ArgumentError, "未知维度" unless Vxlan::Collector::COMMANDS.key?(options[:dimension])

        body = options[:file] ? File.read(options[:file]) : @input.read
        observation = if options[:dimension] == :configuration
          Vxlan::Config.new(model: options[:model]).parse(body, complete: options[:complete])
        else
          Vxlan::RuntimeParser.new(model: options[:model]).parse(options[:dimension], body, complete: options[:complete])
        end
        if options[:json]
          @out.puts JSON.pretty_generate(observation.to_h)
        else
          @out.puts "维度：#{observation.name}；证据：#{observation.status}；记录：#{observation.records.size}"
          @out.puts "诊断：#{observation.issues.map { |issue| issue[:code] }.uniq.join(', ')}" unless observation.issues.empty?
          @out.puts "证据完整性不代表 Fabric 健康。"
        end
        observation.complete? ? 0 : 1
      rescue OptionParser::ParseError, ArgumentError, SystemCallError => error
        @error.puts "离线解析参数或文件错误（#{error.class.name}）；使用 --help 查看参数"
        2
      end
    end
  end
end
