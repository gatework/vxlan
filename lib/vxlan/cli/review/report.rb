# frozen_string_literal: true

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
            additions = @fabric_audit && @fabric_audit[:device_items][document["device"]["host"]]
            advice = Recommendations.combine(advice, additions)
            device = document.fetch("device")
            basename = CLI::Report.device_basename(device)
            write_review(document, basename: basename, source: path, source_sha256: Digest::SHA256.hexdigest(body), advice: advice)
          end
          finish_review(entries, source_batch: File.dirname(File.dirname(sources.first[0])), standalone: standalone)
        end

        # 配置和回退集中于每设备一份 cfg；有限类型动作汇总到批次计划，不接受 cfg 直接执行。
        def write_review(document, basename:, source:, source_sha256:, advice: nil)
          raise ArgumentError, "非法报告名称" unless basename.match?(/\A[A-Za-z0-9_.-]+\z/)
          advice = report_advice(advice || Recommendations.new(document).call).merge(source: source, source_sha256: source_sha256)
          advice[:items] = advice[:items].map(&:dup)
          entry = { device: advice[:device], counts: advice[:counts], basename: basename, report: "devices/#{basename}.txt", source: source,
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
            entry[:changes][id] = { schema_version: 1, platform: "cisco_nxos", device: document.fetch("device"), expected_config_sha256: config_sha256,
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
          summary = { layout_version: 3, mode: "review", status: "incomplete", review_only: true, devices: entries.size, counts: counts, source_batch: source_batch,
            reports: public_entries, plan: "plan.json", plan_sha256: nil, fabric_findings: @fabric_audit ? @fabric_audit[:findings].size : 0 }
          checkpoint("summary.json", summary) if standalone
          plan = { schema_version: 2, platform: "cisco_nxos", mode: "review", devices: public_entries, audits: entries.map { |entry| entry[:advice] },
            changes: entries.each_with_object({}) { |entry, all| all.merge!(entry[:changes]) }, fabric: @fabric_audit && @fabric_audit.reject { |key, _| key == :device_items } }
          body = JSON.pretty_generate(plan) + "\n"
          summary[:plan_sha256] = Digest::SHA256.hexdigest(body)
          publish("plan.json", body)
          publish("plan.json.sha256", summary[:plan_sha256] + "\n")
          events = public_entries.map { |entry| JSON.generate(event: "device_reviewed", reviewed_at: Time.now.utc.iso8601(6), host: entry[:device]["host"], source_sha256: entry[:source_sha256], counts: entry[:counts], report: entry[:report], script: entry[:script], executed: false) }
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
          lines = [ "! 候选配置，未执行；先审阅同名 devices/*.txt；禁止整批直接粘贴。", "! apply 只读取 plan.json 中明确选择的单项，不执行本 cfg。" ]
          items.each do |item|
            lines.concat([ "", "! #{item[:scope]} / #{item[:title]}", "! 计划项：#{item[:plan_id] || '仅审阅草稿，不支持交互执行'}" ])
            lines.concat(item[:prerequisites].map { |condition| "! 条件：#{condition}" })
            lines.concat(item[:commands])
            lines << "! 条件回退（不自动执行）："
            lines.concat(item[:rollback].map { |command| "! #{command}" })
            lines << "! 核查：#{item[:verify].join(' ; ')}"
          end
          lines.join("\n") + "\n"
        end

        # 文本按设备、证据、问题、动作顺序组织，完整跨设备证据位于聚合计划。
        def device_text(entry, document)
          advice, device = entry.values_at(:advice, :device)
          lines = [ "设备：#{device['name']}（#{device['host']}）", "模式：诊断与计划，未执行设备配置", "证据时间：#{advice[:observed_at] || '未知'}", "来源：#{entry[:source]}", "源文件 SHA256：#{entry[:source_sha256]}",
            "建议：#{entry[:counts]}", "命令文件：#{entry[:script] || '未生成'}", "命令 SHA256：#{entry[:script_sha256] || '无'}", "计划文件：plan.json；交互计划项 #{entry[:plans].size} 个", "" ]
          lines << "采集状态：#{document['status']}" if document["status"]
          configuration_time = document.dig("snapshot", "dimensions", "configuration", "evidence", 0, "observed_at")
          lines << "配置证据时间：#{configuration_time}" if configuration_time
          lines << "当前规则未命中；不代表网络健康。" if advice[:items].empty?
          advice[:items].each_with_index do |item, index|
            lines.concat([ "", "#{index + 1}. #{item[:scope]} — #{item[:title]}", "状态：#{item[:status]}；规则：#{item[:code]}", "影响：#{item[:impact]}" ])
            evidence = item[:category] == "fabric" ? Array(item[:evidence]).select { |row| row[:host] == device["host"] } : item[:evidence]
            lines.concat([ "本机依据：", JSON.pretty_generate(evidence) ])
            lines << "跨设备对比：summary.txt；完整原始对比：plan.json 的 audits / fabric。" if item[:category] == "fabric"
            if item[:plan_id]
              lines << "交互计划项：#{item[:plan_id]}"
              lines << "在批次目录运行：vxlan apply --plan plan.json --item #{item[:plan_id]}"
            end
            { prerequisites: "适用条件", blockers: "待决信息", commands: "候选配置（未执行）", rollback: "条件回退", verify: "只读核查", template: "待补模板（不可执行）" }.each do |key, title|
              values = item[key] || []
              lines.concat([ "#{title}：", *values.map { |value| "  #{value}" } ]) if values.any?
            end
            lines << "验收：#{item[:expected]}" if item[:expected]
            lines << "命令参考：#{item[:references].join(' ')}" if item[:references]&.any?
          end
          lines.join("\n") + "\n"
        end

        # 总览先给计数和入口，再给跨设备差异，详细命令只在设备报告/脚本中展示。
        def summary_text(summary)
          entries, counts = summary.values_at(:reports, :counts)
          active = entries.count { |entry| entry[:counts].values.sum.positive? }
          lines = [ "VXLAN 诊断与配置建议；模式：review；未执行设备变更。", "报告完成状态以 summary.json 为准。", "设备：#{entries.size} 台；有建议 #{active} 台；未命中规则 #{entries.size - active} 台（不代表健康）。",
            "建议：待决 #{counts['blocked']}，候选 #{counts['candidate']}，排查 #{counts['investigate']}；Fabric 聚合差异 #{summary[:fabric_findings]} 项。",
            "计划：#{entries.sum { |entry| entry[:plans].size }} 项可交互执行增量；#{entries.count { |entry| entry[:script] }} 份候选脚本。候选数与可执行计划数不同。",
            "阅读顺序：summary.txt → devices/<设备>.txt → scripts/<设备>.cfg → plan.json 中的指定计划项。",
            "evidence/ 保存程序使用的采集证据，日常阅读无需打开；devices/ 只包含可读诊断。",
            "plan.json.sha256 校验聚合计划；events.jsonl 记录本次离线审查，不代表设备会话或下发回执。", "下发必须 --item 选择单项、交互确认、重读配置并核对指纹；无自动批量执行。", "" ]
          entries.sort_by { |entry| [ entry[:counts].values.sum.positive? ? 0 : 1, entry[:device]["name"].to_s ] }.each do |entry|
            lines.concat([ "#{entry[:device]['host']} #{entry[:device]['name']} 待决=#{entry[:counts].fetch('blocked', 0)} 候选=#{entry[:counts].fetch('candidate', 0)} 排查=#{entry[:counts].fetch('investigate', 0)}",
              "  设备报告：#{entry[:report]}", "  命令文件：#{entry[:script] || '未生成'}；可执行计划：#{entry[:plans].size} 项" ])
          end
          lines.concat([ "", @fabric_text ]) if @fabric_text
          lines.join("\n") + "\n"
        end
      end
    end
  end
end
