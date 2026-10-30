# frozen_string_literal: true

require "ctx_runner/evidence"
require "digest"
require "ctx_runner/fingerprint"
require_relative "../../recommendations"
require_relative "../../change_plan"

module Vxlan
  module CLI
    class Review
      # 与 topology 同序编排：先合并诊断，再发布设备报告、脚本、聚合计划和摘要。
      module Report
        # 所有比较先完成；每台设备只发布一次最终建议，不再写后回填 Fabric 差异。
        def build_review(sources, policy: nil, standalone: true)
          documents = sources.map { |entry| entry[2] }
          @fabric_audit = policy && Vxlan::Fabric::Review.new(documents, policy).call
          @fabric_text = @fabric_audit && fabric_text(@fabric_audit, documents)
          entries = sources.map do |path, body, document, initial|
            advice = initial || Recommendations.new(document).call
            additions = @fabric_audit && @fabric_audit[:device_items][document["target"]["host"]]
            advice = Recommendations.combine(advice, additions)
            device = document.fetch("target")
            basename = CLI::Report.target_basename(device)
            write_review(document, basename: basename, source: path, source_sha256: Digest::SHA256.hexdigest(body), advice: advice)
          end
          finish_review(entries, source_batch: File.dirname(File.dirname(sources.first[0])), standalone: standalone)
        end

        # 配置和回退集中于每设备一份 cfg；有限类型动作汇总到批次计划，不接受 cfg 直接执行。
        def write_review(document, basename:, source:, source_sha256:, advice: nil)
          raise ArgumentError, "Invalid report name" unless basename.match?(/\A[A-Za-z0-9_.-]+\z/)
          advice = report_advice(advice || Recommendations.new(document).call).merge(source: source, source_sha256: source_sha256)
          advice[:items] = advice[:items].map(&:dup)
          entry = { target: advice[:target], counts: advice[:counts], basename: basename, report: "devices/#{basename}.txt", source: source,
            source_sha256: source_sha256, script: nil, script_sha256: nil, plans: [], changes: {}, advice: advice }
          config = Config::Evidence.complete_record(document)
          config_sha256 = nil
          advice[:items].each do |item|
            next unless @scripts && config && item[:status] == "candidate" && item[:change]
            plan = ChangePlan.candidate(item[:change], config: config)
            next unless plan
            change = plan.to_h
            id = [ basename, change["kind"], "vlan#{change['vlan']}", change["direction"], CtxRunner::Fingerprint.call(change)[0, 12] ].compact.join("--")
            config_sha256 ||= CtxRunner::Fingerprint.call(config)
            entry[:changes][id] = { schema_version: CtxRunner::Evidence::VERSION, kind: "change", platform: "cisco_nxos", target: document.fetch("target"), expected_config_sha256: config_sha256,
              source: source, source_sha256: source_sha256, change: change, commands: plan.commands, rollback: plan.rollback,
              scope: item[:scope], title: item[:title], prerequisites: item[:prerequisites], impact: item[:impact], verify: item[:verify] }
            item[:plan_id] = id
            entry[:plans] << id
          end
          candidates = advice[:items].select { |item| item[:status] == "candidate" && item[:commands].any? }
          if @scripts && candidates.any?
            script = script_text(candidates)
            entry[:script] = "scripts/#{basename}.cfg"
            entry[:script_sha256] = Digest::SHA256.hexdigest(script)
            prepare_directory(File.join(directory, "scripts"))
            publish(entry[:script], script)
          end
          prepare_directory(File.join(directory, "devices"))
          publish(entry[:report], device_text(entry, document))
          entry
        end

        # JSON 状态最后提交；中途失败保留未完成检查点和已经发布的事实。
        def finish_review(entries, source_batch:, standalone: true)
          counts = entries.each_with_object(Hash.new(0)) { |entry, total| entry[:counts].each { |key, count| total[key] += count } }
          public_entries = entries.map { |entry| entry.reject { |key, _| %i[advice changes].include?(key) } }
          summary = { schema_version: CtxRunner::Evidence::VERSION, kind: "review", layout_version: 3, mode: "review", status: "incomplete", review_only: true, devices: entries.size, counts: counts, source_batch: source_batch,
            reports: public_entries, plan: "plan.json", plan_sha256: nil, fabric_findings: @fabric_audit ? @fabric_audit[:findings].size : 0 }
          checkpoint("summary.json", summary) if standalone
          plan = { schema_version: CtxRunner::Evidence::VERSION, kind: "change_plan", platform: "cisco_nxos", mode: "review", devices: public_entries, audits: entries.map { |entry| entry[:advice] },
            changes: entries.each_with_object({}) { |entry, all| all.merge!(entry[:changes]) }, fabric: @fabric_audit && @fabric_audit.reject { |key, _| key == :device_items } }
          body = JSON.pretty_generate(plan, max_nesting: 128) + "\n"
          summary[:plan_sha256] = Digest::SHA256.hexdigest(body)
          publish("plan.json", body)
          publish("plan.json.sha256", summary[:plan_sha256] + "\n")
          events = public_entries.map { |entry| JSON.generate(event: "device_reviewed", reviewed_at: Time.now.utc.iso8601(6), host: entry[:target]["host"], source_sha256: entry[:source_sha256], counts: entry[:counts], report: entry[:report], script: entry[:script], executed: false) }
          publish("events.jsonl", events.join("\n") + (events.empty? ? "" : "\n"))
          text = summary_text(summary)
          if standalone
            publish("summary.txt", text)
            finalize("summary.json", summary.merge(status: "complete"), checkpoint: summary)
          end
          @review_summary, @review_text = summary.merge(status: "complete"), text
          @review_summary
        end

        private

        # 默认只输出诊断和核查步骤；命令和动作只在 --scripts 时保留。
        def report_advice(advice)
          return advice if @scripts
          advice.merge(items: advice[:items].map { |item| item.reject { |key, _| %i[change template].include?(key) }.merge(commands: [], rollback: []) })
        end

        # 每项包含作用域、条件、命令及注释化回退，不将多项当成原子变更。
        def script_text(items)
          lines = [ "! Candidate configuration, not executed; review the matching devices/*.txt first. Do not paste the entire batch.", "! apply reads only the explicitly selected item from plan.json; it does not execute this cfg file." ]
          items.each do |item|
            lines.concat([ "", "! #{item[:scope]} / #{item[:title]}", "! Plan item: #{item[:plan_id] || 'Review draft only; interactive execution unsupported'}" ])
            lines.concat(item[:prerequisites].map { |condition| "! Prerequisite: #{condition}" })
            lines.concat(item[:commands])
            lines << "! Conditional rollback (not executed automatically): "
            lines.concat(item[:rollback].map { |command| "! #{command}" })
            lines << "! Verification: #{item[:verify].join(' ; ')}"
          end
          lines.join("\n") + "\n"
        end

        # 文本按设备、证据、问题、动作顺序组织，完整跨设备证据位于聚合计划。
        def device_text(entry, document)
          advice, device = entry.values_at(:advice, :target)
          lines = [ "Device: #{device['name']} (#{device['host']})", "Mode: diagnostics and planning; no device configuration executed", "Evidence time: #{advice[:observed_at] || 'unknown'}", "Source: #{entry[:source]}", "Source file SHA256: #{entry[:source_sha256]}",
            "Recommendations: #{entry[:counts]}", "Command file: #{entry[:script] || 'not generated'}", "Command SHA256: #{entry[:script_sha256] || 'none'}", "Plan file: plan.json; interactive plan items: #{entry[:plans].size} items", "" ]
          lines << "Collection status: #{document['status']}" if document["status"]
          configuration_time = document.dig("snapshot", "observations", "configuration", "evidence", 0, "observed_at")
          lines << "Configuration evidence time: #{configuration_time}" if configuration_time
          lines << "No current rules matched; this does not establish network health." if advice[:items].empty?
          advice[:items].each_with_index do |item, index|
            lines.concat([ "", "#{index + 1}. #{item[:scope]} — #{item[:title]}", "Status: #{item[:status]}; rule: #{item[:code]}", "Impact: #{item[:impact]}" ])
            evidence = item[:category] == "fabric" ? Array(item[:evidence]).select { |row| row[:host] == device["host"] } : item[:evidence]
            lines.concat([ "Local evidence: ", JSON.pretty_generate(evidence, max_nesting: 128) ])
            lines << "Cross-device comparison: summary.txt; full raw comparison: audits / fabric in plan.json." if item[:category] == "fabric"
            if item[:plan_id]
              lines << "Interactive plan item: #{item[:plan_id]}"
              lines << "Run in the batch directory: vxlan apply --plan plan.json --item #{item[:plan_id]}"
            end
            { prerequisites: "Prerequisites", blockers: "Unresolved information", commands: "Candidate configuration (not executed)", rollback: "Conditional rollback", verify: "Read-only verification", template: "Incomplete template (not executable)" }.each do |key, title|
              values = item[key] || []
              lines.concat([ "#{title}: ", *values.map { |value| "  #{value}" } ]) if values.any?
            end
            lines << "Acceptance: #{item[:expected]}" if item[:expected]
            lines << "Command reference: #{item[:references].join(' ')}" if item[:references]&.any?
          end
          lines.join("\n") + "\n"
        end

        # 总览先给计数和入口，再给跨设备差异，详细命令只在设备报告/脚本中展示。
        def summary_text(summary)
          entries, counts = summary.values_at(:reports, :counts)
          active = entries.count { |entry| entry[:counts].values.sum.positive? }
          lines = [ "VXLAN diagnostics and configuration recommendations; mode: review; no device changes executed.", "Report completion status is authoritative in summary.json.", "Devices: #{entries.size} devices; with recommendations #{active} devices; no rules matched #{entries.size - active} devices (does not establish health).",
            "Recommendations: unresolved #{counts['blocked']}, candidates #{counts['candidate']}, investigations #{counts['investigate']}; aggregated Fabric differences #{summary[:fabric_findings]} items.",
            "Plan: #{entries.sum { |entry| entry[:plans].size }} changes available for interactive execution; #{entries.count { |entry| entry[:script] }} candidate scripts. Candidate counts differ from executable plan counts.",
            "Read in order: summary.txt -> devices/<device>.txt -> scripts/<device>.cfg -> the selected plan item in plan.json.",
            "evidence/ stores collection evidence used by the program; routine review does not require opening it. devices/ contains readable diagnostics only.",
            "plan.json.sha256 verifies the aggregate plan; events.jsonl records this offline review, not device sessions or execution receipts.", "Applying requires selecting one --item, interactive confirmation, configuration readback and fingerprint verification; there is no automatic bulk execution.", "" ]
          entries.sort_by { |entry| [ entry[:counts].values.sum.positive? ? 0 : 1, entry[:target]["name"].to_s ] }.each do |entry|
            lines.concat([ "#{entry[:target]['host']} #{entry[:target]['name']} unresolved=#{entry[:counts].fetch('blocked', 0)} candidates=#{entry[:counts].fetch('candidate', 0)} investigations=#{entry[:counts].fetch('investigate', 0)}",
              "  Device report: #{entry[:report]}", "  Command file: #{entry[:script] || 'not generated'}; executable plans: #{entry[:plans].size} items" ])
          end
          lines.concat([ "", @fabric_text ]) if @fabric_text
          lines.join("\n") + "\n"
        end
      end
    end
  end
end
