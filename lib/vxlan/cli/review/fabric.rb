# frozen_string_literal: true

require "yaml"
require "ctx_cli/input"
require "ctx_runner/fingerprint"
require_relative "../../fabric/review"

module Vxlan
  module CLI
    class Review
      # Fabric 文本只呈现已有发现，不重新计算基线或混入下发决策。
      module Fabric
        # 相同事实合并展示；规则版本保持匹配顺序，完整证据由聚合计划保存。
        def fabric_text(audit, documents)
          by_host = documents.to_h { |document| [ document.fetch("device").fetch("host"), document ] }
          lines = [ "Fabric 共同业务一致性", "范围：按显式 Fabric 和角色比较共同 VNI；Leaf、Border 分开比较，Spine 检查业务承载配置。", "部署事实联合 VLAN/NVE/EVPN 识别；不完整部署不等于未部署。保留部署范围差异。", "ACL 比较包含有序规则与依赖对象；不以多数无 ACL 为删除依据。", "" ]
          inventory = audit[:inventory]
          if inventory
            lines << "覆盖：已纳入 #{inventory[:assigned].size} 台；未纳入 #{inventory[:unassigned].size} 台；缺证据 #{inventory[:missing].size} 台。"
            inventory[:groups].each do |fabric, roles|
              lines << "#{fabric}：Leaf #{roles['leaves'].size} / Border #{roles['borders'].size} / Spine #{roles['spines'].size}"
              %w[leaves borders].each do |role|
                services = audit[:coverage].select { |entry| entry[:fabric] == fabric && entry[:role] == role }
                partial = services.select { |entry| entry[:incomplete].any? }
                lines << "  #{role}：已部署业务 #{services.size}，多设备共同业务 #{services.count { |entry| entry[:deployed].size >= 2 }}，关联不完整 #{partial.size}。"
                partial.each { |entry| lines << "    VNI #{entry[:vni]} 待补齐：#{entry[:incomplete].map { |host| by_host.dig(host, 'device', 'name') || host }.join('、')}" }
              end
            end
            lines << ""
          end
          audit[:findings].each_with_index do |finding, index|
            lines << "#{index + 1}. #{finding[:fabric]} / #{finding[:role] || '全 Fabric'} / #{finding[:vni] ? "VNI #{finding[:vni]}" : '公共策略'}：#{finding[:title]}"
          end
          audit[:findings].each_with_index do |finding, index|
            lines.concat([ "", "[#{index + 1}] #{finding[:fabric]} / #{finding[:role] || '全 Fabric'} / #{finding[:vni] || '公共策略'} — #{finding[:title]}", "规则：#{finding[:code]}" ])
            evidence = finding[:evidence]
            if finding[:code] == "fabric_address_group"
              defined = evidence.filter_map { |row| row[:value] }
              common = defined.reduce { |all, members| all & members } || []
              lines << "  已定义版本的共同成员（不代表批准基线）：#{common.empty? ? '无' : common.join('、')}"
              evidence.group_by { |row| row[:value] }.each do |members, rows|
                names = rows.map { |row| by_host.dig(row[:host], "device", "name") || row[:host] }
                value = members ? "#{members.size} 个成员；共同成员之外：#{(members - common).empty? ? '无' : (members - common).join('、')}" : "未提供定义或未采集对象证据"
                lines.concat([ "  #{names.join('、')}", "    #{value}" ])
              end
              next
            end
            unless evidence.is_a?(Array) && evidence.all? { |row| row.is_a?(Hash) }
              lines << JSON.pretty_generate(evidence)
              next
            end
            grouped = evidence.group_by do |row|
              value = row.key?(:value) ? row[:value] : row.reject { |key, _| %i[host name vlan entries semantics].include?(key) }
              value = value.reject { |key, _| key == :entries } if value.is_a?(Hash)
              if row[:semantics]
                policy = row[:policy] ? "规则与依赖版本 #{CtxRunner::Fingerprint.call(row[:policy])[0, 12]}" : "依赖对象未验证"
                value = "#{row[:entries].size} 条规则，#{policy}"
              end
              [ row[:vlan] || row[:interface] || "公共", display_fabric_value(value) ]
            end
            grouped.each do |(vlan, value), members|
              names = members.map { |row| row[:name] || by_host.dig(row[:host], "device", "name") || row[:host] }
              lines.concat([ "  VLAN/接口 #{vlan}：#{value}", "    #{names.join('、')}" ])
            end
            if evidence.any? { |row| row[:semantics] }
              evidence.group_by { |row| row[:semantics] }.each_with_index do |(rules, members), variant|
                lines << "  规则版本 #{variant + 1}：#{members.map { |row| by_host.dig(row[:host], 'device', 'name') || row[:host] }.join('、')}"
                lines.concat(rules.map { |rule| "    #{rule['action']} #{rule['expression']}" })
              end
            end
          end
          lines.join("\n") + "\n"
        end

        # 机器字段转换为运维读法，显式保留缺失和未知。
        def display_fabric_value(value)
          if value.is_a?(Hash) && value.key?(:acl)
            return "未挂载 ACL" unless value[:acl]
            return "#{value[:acl]}；本机缺少定义" unless value[:defined]
            return "#{value[:acl]}；已定义，但依赖对象未验证" unless value[:policy_verified]
            "#{value[:acl]}；已定义，版本 #{value[:digest].to_s[0, 12]}"
          elsif value.is_a?(Array)
            value.empty? ? "未配置地址" : value.join("、")
          elsif value.nil?
            "未提供"
          elsif value.is_a?(Hash)
            JSON.generate(value)
          else
            value.to_s
          end
        end

        # 实时收尾读取已经保存的事实；审查摘要交给采集摘要一起发布，避免相互覆盖。
        def review_collected_fabric(policy)
          sources = Dir[File.join(directory, "evidence", "*.json")].sort.map do |path|
            body = CtxCli::Input.read(path: path)
            [ File.expand_path(path), body, JSON.parse(body) ]
          end
          build_review(sources, policy: policy, standalone: false) unless sources.empty?
        end
      end
    end
  end
end
