# frozen_string_literal: true

require "json"
require "time"
require "tempfile"
require "fileutils"

module Vxlan
  module CLI
    # 宿主按批次保存事实；配置事实可能敏感，目录 0700、文件 0600。
    class Report
      attr_reader :directory

      # 仅交付发布阶段，不保留底层异常正文或敏感报告内容。
      class Error < IOError
        attr_reader :relative, :phase

        def initialize(relative:, phase:, committed:)
          @relative, @phase, @committed = relative.freeze, phase, committed
          super("报告写入失败：#{relative}；阶段 #{phase}；#{committed ? '已替换，收尾未确认' : '尚未替换'}")
        end

        def committed? = @committed
      end

      # 批次目录排他创建，重复时间戳不会覆盖上一批次。
      def initialize(root)
        FileUtils.mkdir_p(root, mode: 0o700)
        stat = File.lstat(root)
        unless stat.directory? && (stat.mode & 0o077).zero?
          raise ArgumentError, "报告根目录须为真实私有目录，权限0700；请设置独立目录并检查 chmod 0700"
        end
        stem = Time.now.utc.strftime("%Y-%m-%d_%H-%M-%S")
        sequence = 0
        begin
          @directory = File.join(root, sequence.zero? ? stem : "#{stem}_#{sequence}")
          Dir.mkdir(directory, 0o700)
        rescue Errno::EEXIST
          sequence += 1
          retry
        end
        Dir.mkdir(File.join(directory, "devices"), 0o700)
      end

      # 每台完成后立即原子保存，即使批次随后取消仍可读取已完成证据。
      def write(result, snapshot: nil)
        device = result.fetch(:device)
        name = "#{device.fetch('name').gsub(/[^A-Za-z0-9_.-]/, '_')[0, 100]}-#{device.fetch('host').tr(':', '_')}"
        # 保存状态属于批次宿主；不能让正在发布的文件预先声明自身已保存。
        body = result.reject { |key, _| key == :report_saved }.merge(snapshot: snapshot && snapshot.to_h)
        publish("devices/#{name}.json", JSON.pretty_generate(serializable(body)) + "\n")
        lines = [ "设备：#{device.fetch('name')}（#{device.fetch('host')}）", "证据：#{result.fetch(:status)}", "此结果不代表 Fabric 健康。" ]
        result.fetch(:dimensions, {}).each do |dimension, facts|
          lines << "#{dimension}：#{facts.fetch(:status)}；记录 #{facts.fetch(:records)}；诊断 #{facts.fetch(:issues).join(', ')}"
        end
        lines << "错误：#{result[:error]}" if result[:error]
        publish("devices/#{name}.txt", lines.join("\n") + "\n")
      end

      # 摘要不嵌入配置事实，只汇总状态与诊断，供终端和自动化共用。
      def finish(results, interrupted: false, requested: [], report_error: nil, execution_error: nil)
        completed_hosts = results.map { |r| r.fetch(:device).fetch("host") }
        pending = requested.reject { |device| completed_hosts.include?(device.fetch("host")) }
        complete = !report_error && !execution_error && pending.empty? && results.any? && results.all? { |r| r[:status] == :complete && r[:report_saved] != false }
        summary = { status: interrupted ? :interrupted : (complete ? :complete : :incomplete),
          total: [ requested.size, results.size ].max, completed: results.size, pending: pending, counts: results.map { |r| r[:status] }.tally, devices: results,
          directory: directory, evidence_only: true }
        summary[:report_error] = report_error if report_error
        summary[:execution_error] = execution_error if execution_error
        publish("summary.json", JSON.pretty_generate(serializable(summary)) + "\n")
        text = [ "VXLAN 采集：#{summary.fetch(:status)}；完成 #{results.size} 台", "分类：#{summary.fetch(:counts)}", "证据完整性不代表 Fabric 健康。" ]
        text << "报告错误：#{report_error}" if report_error
        text << "执行错误：#{execution_error}" if execution_error
        results.each do |r|
          saved = r[:report_saved] == true ? "已保存" : "保存未确认"
          text << "#{r[:device]['host']}\t#{r[:device]['name']}\t#{r[:status]}\t#{saved}\t#{r[:error]}"
        end
        pending.each { |device| text << "#{device['host']}\t#{device['name']}\t未采集" }
        publish("summary.txt", text.join("\n") + "\n")
        summary
      end

      private

      # Time 使用 ISO-8601，递归转换 Data 只发生在显式持久化边界。
      def serializable(value)
        case value
        when Time then value.iso8601(6)
        when Data then serializable(value.to_h)
        when Hash then value.transform_values { |item| serializable(item) }
        when Array then value.map { |item| serializable(item) }
        else value
        end
      end

      # 临时文件与目标在同一目录，写入失败不发布半份报告。
      def publish(relative, body)
        target = File.join(directory, relative)
        phase, committed = :temporary_file, false
        Tempfile.create([ ".vxlan-", ".tmp" ], File.dirname(target)) do |file|
          file.chmod(0o600)
          phase = :write
          file.write(body)
          phase = :file_sync
          file.flush
          file.fsync
          phase = :rename
          File.rename(file.path, target)
          committed = true
          phase = :directory_sync
          File.open(File.dirname(target), File::RDONLY | File::NOFOLLOW) { |parent| parent.fsync }
          phase = :cleanup
        end
      rescue SystemCallError, IOError, NotImplementedError
        raise Error.new(relative: relative, phase: phase, committed: committed), cause: nil
      end
    end
  end
end
