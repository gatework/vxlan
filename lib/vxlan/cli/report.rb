# frozen_string_literal: true

require "json"
require "time"
require "ctx_runner/report"
require "ctx_runner/document"
require "ctx_runner/evidence"
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
      def self.target_basename(device)
        "#{device.fetch('name').gsub(/[^A-Za-z0-9_.-]/, '_')[0, 100]}-#{device.fetch('host').gsub(/[^A-Za-z0-9_.-]/, '_')}"
      end

      # 每台完成后立即原子保存，即使批次随后取消仍可读取已完成证据。
      def write(result, snapshot: nil)
        device = result.fetch(:target)
        name = self.class.target_basename(device)
        # 保存状态属于批次宿主；不能让正在发布的文件预先声明自身已保存。
        body = result.reject { |key, _| key == :report_saved }.merge(snapshot: snapshot && snapshot.to_h)
        document = CtxRunner::Evidence.wrap(body, kind: "collection")
        advice = report_advice(Recommendations.new(document).call)
        document = document.merge("recommendations" => advice)
        json = JSON.pretty_generate(document, max_nesting: 128) + "\n"
        prepare_directory(File.join(directory, "evidence"))
        publish("evidence/#{name}.json", json)
        write_review(document, basename: name, source: File.join(directory, "evidence", "#{name}.json"), source_sha256: Digest::SHA256.hexdigest(json), advice: advice)
      end

      # 摘要不嵌入配置事实，只汇总状态与诊断，供终端和自动化共用。
      def finish(results, interrupted: false, requested: [], report_error: nil, execution_error: nil, output_error: nil)
        @report.finish(results, interrupted: interrupted, requested: requested, report_error: report_error,
          execution_error: execution_error, output_error: output_error, review: @review_summary) do |summary|
          pending = summary.fetch("pending")
          text = [ "VXLAN evidence: #{summary.fetch('status')}; completed #{summary.fetch('completed')} devices", "Categories: #{summary.fetch('counts')}", "Complete evidence does not establish Fabric health." ]
          text << "Per-device diagnostics: devices/; candidate scripts: scripts/; no candidate configuration was executed."
          text << @review_text if @review_text
          text << "Batch report status: see summary.json; evidence status in text does not confirm report publication."
          text << "Report error: #{summary['report_error']}" if summary["report_error"]
          text << "Execution error: #{summary['execution_error']}" if summary["execution_error"]
          text << "Progress output error: #{summary['output_error']['error_type']}; device results retained" if summary["output_error"]
          summary.fetch("devices").each do |r|
            saved = r["report_saved"] == true ? "saved" : "persistence unconfirmed"
            text << "#{r['target']['host']}\t#{r['target']['name']}\t#{r['status']}\t#{saved}\t#{r['error']}"
          end
          pending.each { |device| text << "#{device['host']}\t#{device['name']}\tnot collected" }
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
