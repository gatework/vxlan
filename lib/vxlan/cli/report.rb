# frozen_string_literal: true

require "json"
require "time"
require "tempfile"
require "fileutils"
require_relative "review/report"
require_relative "review/fabric"

module Vxlan
  module CLI
    # 宿主按批次保存事实；配置事实可能敏感，目录 0700、文件 0600。
    class Report
      include Review::Report
      include Review::Fabric

      attr_reader :directory

      # 采集和离线审查共用稳定名称，保留 IPv6 地址并避免设备名成为路径。
      def self.device_basename(device)
        "#{device.fetch('name').gsub(/[^A-Za-z0-9_.-]/, '_')[0, 100]}-#{device.fetch('host').gsub(/[^A-Za-z0-9_.-]/, '_')}"
      end

      # 仅交付发布阶段，不保留底层异常正文或敏感报告内容。
      class Error < IOError
        attr_reader :relative, :phase

        # 保留安全的发布阶段与提交状态，不携带底层异常正文。
        def initialize(relative:, phase:, committed:)
          @relative, @phase, @committed = relative.freeze, phase, committed
          super("报告写入失败：#{relative}；阶段 #{phase}；#{committed ? '已替换，收尾未确认' : '尚未替换'}")
        end

        # 区分原子替换已完成与目录同步尚未确认。
        def committed? = @committed
      end

      # 批次目录排他创建，重复时间戳不会覆盖上一批次。
      def initialize(root, scripts: false)
        @scripts = scripts
        root = File.expand_path(root)
        prepare_directory(root)
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
        sync_directory(root)
      end

      # 每台完成后立即原子保存，即使批次随后取消仍可读取已完成证据。
      def write(result, snapshot: nil)
        device = result.fetch(:device)
        name = self.class.device_basename(device)
        # 保存状态属于批次宿主；不能让正在发布的文件预先声明自身已保存。
        body = result.reject { |key, _| key == :report_saved }.merge(snapshot: snapshot && snapshot.to_h)
        document = JSON.parse(JSON.generate(serializable(body)))
        advice = report_advice(Recommendations.new(document).call)
        document["recommendations"] = advice
        json = JSON.pretty_generate(document) + "\n"
        prepare_directory(File.join(directory, "evidence"))
        publish("evidence/#{name}.json", json)
        write_review(document, basename: name, source: File.join(directory, "evidence", "#{name}.json"), source_sha256: Digest::SHA256.hexdigest(json), advice: advice)
      end

      # 摘要不嵌入配置事实，只汇总状态与诊断，供终端和自动化共用。
      def finish(results, interrupted: false, requested: [], report_error: nil, execution_error: nil, output_error: nil)
        @recovery_failed = false
        # 按地址索引一次，避免大批次逐个扫描所有已完成结果。
        completed_hosts = results.to_h { |result| [ result.fetch(:device).fetch("host"), true ] }
        pending = requested.reject { |device| completed_hosts.key?(device.fetch("host")) }
        complete = !report_error && !execution_error && !output_error && pending.empty? && results.any? && results.all? { |r| r[:status] == :complete && r[:report_saved] != false }
        summary = { status: interrupted ? :interrupted : (complete ? :complete : :incomplete),
          total: [ requested.size, results.size ].max, completed: results.size, pending: pending, counts: results.map { |r| r[:status] }.tally, devices: results,
          directory: directory, evidence_only: true }
        summary[:review] = @review_summary if @review_summary
        summary[:report_error] = report_error if report_error
        summary[:execution_error] = execution_error if execution_error
        summary[:output_error] = output_error if output_error
        # 先保存未完成检查点；文本发布或最终提交失败都不能留下成功摘要。
        checkpoint = summary.merge(status: interrupted ? :interrupted : :incomplete,
          report_error: report_error || :report_finalization_unconfirmed)
        checkpoint_body = JSON.pretty_generate(serializable(checkpoint)) + "\n"
        begin
          publish("summary.json", checkpoint_body)
        rescue Error, Interrupt
          invalidate_completed_summary
          raise
        end
        text = [ "VXLAN 证据：#{summary.fetch(:status)}；完成 #{results.size} 台", "分类：#{summary.fetch(:counts)}", "证据完整性不代表 Fabric 健康。" ]
        text << "逐设备诊断：devices/；候选脚本：scripts/；所有候选配置未执行。"
        text << @review_text if @review_text
        text << "批次报告状态：参见 summary.json；文本中的证据状态不确认报告发布完成。"
        text << "报告错误：#{report_error}" if report_error
        text << "执行错误：#{execution_error}" if execution_error
        text << "进度输出错误：#{output_error[:error_type]}；设备结果已保留" if output_error
        results.each do |r|
          saved = r[:report_saved] == true ? "已保存" : "保存未确认"
          text << "#{r[:device]['host']}\t#{r[:device]['name']}\t#{r[:status]}\t#{saved}\t#{r[:error]}"
        end
        pending.each { |device| text << "#{device['host']}\t#{device['name']}\t未采集" }
        publish("summary.txt", text.join("\n") + "\n")
        begin
          publish("summary.json", JSON.pretty_generate(serializable(summary)) + "\n")
        rescue Error => error
          # 未替换时原检查点仍安全，不做可能破坏它的多余恢复写入。
          restore_checkpoint(checkpoint_body) if error.committed?
          raise
        rescue Interrupt
          checkpoint[:status] = :interrupted
          restore_checkpoint(JSON.pretty_generate(serializable(checkpoint)) + "\n")
          raise
        end
        summary
      end

      # 每次发送配置前后发布检查点；失败由执行器停止后续写入。
      def write_execution(state)
        publish("execution.json", JSON.pretty_generate(state) + "\n")
      end

      # 恢复写入或删除受阻时，调用方须把退出码及此状态作为未确认诊断。
      def recovery_failed? = @recovery_failed == true

      private

      # 新建目录的名字属于父目录；文件 fsync 不能替代这条持久化链。
      def prepare_directory(path)
        missing, parent = [], path
        until File.directory?(parent)
          missing << parent
          parent = File.dirname(parent)
        end
        FileUtils.mkdir_p(path, mode: 0o700)
        missing.reverse_each do |created|
          parent = File.dirname(created)
          sync_directory(File.symlink?(parent) ? File.realpath(parent) : parent)
        end
      end

      # 批次创建与文件发布共享目录同步边界，失败直接交还宿主停止执行。
      def sync_directory(path)
        File.open(path, File::RDONLY | File::NOFOLLOW) { |parent| parent.fsync }
      end

      # 新一次收尾失败时，旧成功摘要不再代表当前状态；安全检查点继续保留。
      def invalidate_completed_summary
        Thread.handle_interrupt(Exception => :never) do
          saved = JSON.parse(File.read(File.join(directory, "summary.json")))
          discard_summary if saved["status"] == "complete"
        end
      rescue Errno::ENOENT
        nil
      rescue SystemCallError, JSON::ParserError, Interrupt
        @recovery_failed = true
      end

      # 屏蔽恢复中的次级取消，始终把最先观察到的发布失败或取消交还调用方。
      def restore_checkpoint(body, relative: "summary.json")
        Thread.handle_interrupt(Exception => :never) do
          begin
            publish(relative, body)
          rescue Error, Interrupt => error
            @recovery_failed = true
            discard_summary(relative: relative) unless error.is_a?(Error) && error.committed?
          end
        end
      rescue Interrupt
        @recovery_failed = true
      end

      # 存储拒绝恢复时尽力移除不可信摘要，不删除已获得的设备事实。
      def discard_summary(relative: "summary.json")
        File.unlink(File.join(directory, relative))
      rescue Errno::ENOENT
        nil
      rescue SystemCallError
        @recovery_failed = true
      end

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
          sync_directory(File.dirname(target))
          phase = :cleanup
        end
      rescue SystemCallError, IOError, NotImplementedError
        raise Error.new(relative: relative, phase: phase, committed: committed), cause: nil
      end
    end
  end
end
