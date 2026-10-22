# frozen_string_literal: true

require "json"
require "time"
require "ctx_runner/report"
require "ctx_runner/document"
require_relative "review/report"
require_relative "review/fabric"

module Vxlan
  module CLI
    # 宿主按批次保存事实；配置事实可能敏感，目录 0700、文件 0600。
    class Report
      include Review::Report
      include Review::Fabric

      # 私有证据发布由公共业务对象管理；本类只组织领域报告。
      class Error < CtxRunner::Report::Error; end

      def initialize(root, scripts: false)
        @scripts = scripts
        @report = CtxRunner::Report.new(root, error_class: Error)
      end

      def directory = @report.directory
      def recovery_failed? = @report.recovery_failed?
      def write_execution(state) = @report.write_execution(state)

      # 采集和离线审查共用稳定名称，保留 IPv6 地址并避免设备名成为路径。
      def self.device_basename(device)
        "#{device.fetch('name').gsub(/[^A-Za-z0-9_.-]/, '_')[0, 100]}-#{device.fetch('host').gsub(/[^A-Za-z0-9_.-]/, '_')}"
      end

      # 每台完成后立即原子保存，即使批次随后取消仍可读取已完成证据。
      def write(result, snapshot: nil)
        device = result.fetch(:device)
        name = self.class.device_basename(device)
        # 保存状态属于批次宿主；不能让正在发布的文件预先声明自身已保存。
        body = result.reject { |key, _| key == :report_saved }.merge(snapshot: snapshot && snapshot.to_h)
        document = CtxRunner::Document.call(body)
        advice = report_advice(Recommendations.new(document).call)
        document = document.merge("recommendations" => advice)
        json = JSON.pretty_generate(document) + "\n"
        prepare_directory(File.join(directory, "evidence"))
        publish("evidence/#{name}.json", json)
        write_review(document, basename: name, source: File.join(directory, "evidence", "#{name}.json"), source_sha256: Digest::SHA256.hexdigest(json), advice: advice)
      end

      # 摘要不嵌入配置事实，只汇总状态与诊断，供终端和自动化共用。
      def finish(results, interrupted: false, requested: [], report_error: nil, execution_error: nil, output_error: nil)
        @report.finish(results, interrupted: interrupted, requested: requested, report_error: report_error,
          execution_error: execution_error, output_error: output_error, review: @review_summary) do |summary|
          pending = summary.fetch(:pending)
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
          text.join("\n") + "\n"
        end
      end

      private

      # 保持领域呈现接口，事务与恢复状态仅在公共报告中实现。
      def prepare_directory(path) = @report.prepare_directory(path)
      def publish(relative, body) = @report.publish(relative, body)
      def checkpoint(relative, value) = @report.checkpoint(relative, value)
      def finalize(relative, summary, checkpoint:) = @report.finalize(relative, summary, checkpoint: checkpoint)
    end
  end
end
