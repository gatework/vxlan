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
          by_host = documents.to_h { |document| [ document.fetch("target").fetch("host"), document ] }
          lines = [ "Fabric shared-service consistency", "Scope: compare shared VNIs within explicit Fabrics and roles; compare Leaf and Border separately, and check Spine for service-bearing configuration.", "Deployment facts combine VLAN/NVE/EVPN evidence; incomplete deployment does not mean absence. Deployment scope differences are retained.", "ACL comparison includes ordered rules and dependencies; a majority without an ACL is not grounds for removal.", "" ]
          inventory = audit[:inventory]
          if inventory
            lines << "Coverage: included #{inventory[:assigned].size} devices; excluded #{inventory[:unassigned].size} devices; missing evidence #{inventory[:missing].size} devices."
            inventory[:groups].each do |fabric, roles|
              lines << "#{fabric}: Leaf #{roles['leaves'].size} / Border #{roles['borders'].size} / Spine #{roles['spines'].size}"
              %w[leaves borders].each do |role|
                services = audit[:coverage].select { |entry| entry[:fabric] == fabric && entry[:role] == role }
                partial = services.select { |entry| entry[:incomplete].any? }
                lines << "  #{role}: deployed services #{services.size}, services shared across devices #{services.count { |entry| entry[:deployed].size >= 2 }}, incomplete associations #{partial.size}."
                partial.each { |entry| lines << "    VNI #{entry[:vni]} missing: #{entry[:incomplete].map { |host| by_host.dig(host, 'target', 'name') || host }.join(', ')}" }
              end
            end
            lines << ""
          end
          audit[:findings].each_with_index do |finding, index|
            lines << "#{index + 1}. #{finding[:fabric]} / #{finding[:role] || 'entire Fabric'} / #{finding[:vni] ? "VNI #{finding[:vni]}" : 'shared policy'}: #{finding[:title]}"
          end
          audit[:findings].each_with_index do |finding, index|
            lines.concat([ "", "[#{index + 1}] #{finding[:fabric]} / #{finding[:role] || 'entire Fabric'} / #{finding[:vni] || 'shared policy'} — #{finding[:title]}", "Rule: #{finding[:code]}" ])
            evidence = finding[:evidence]
            if finding[:code] == "fabric_address_group"
              defined = evidence.filter_map { |row| row[:value] }
              common = defined.reduce { |all, members| all & members } || []
              lines << "  Members common to defined versions (not an approved baseline): #{common.empty? ? 'none' : common.join(', ')}"
              evidence.group_by { |row| row[:value] }.each do |members, rows|
                names = rows.map { |row| by_host.dig(row[:host], "target", "name") || row[:host] }
                value = members ? "#{members.size} members; outside the common set: #{(members - common).empty? ? 'none' : (members - common).join(', ')}" : "No definition provided or object evidence not collected"
                lines.concat([ "  #{names.join(', ')}", "    #{value}" ])
              end
              next
            end
            unless evidence.is_a?(Array) && evidence.all? { |row| row.is_a?(Hash) }
              lines << JSON.pretty_generate(evidence, max_nesting: 128)
              next
            end
            grouped = evidence.group_by do |row|
              value = row.key?(:value) ? row[:value] : row.reject { |key, _| %i[host name vlan entries semantics].include?(key) }
              value = value.reject { |key, _| key == :entries } if value.is_a?(Hash)
              if row[:semantics]
                policy = row[:policy] ? "Rule and dependency version #{CtxRunner::Fingerprint.call(row[:policy])[0, 12]}" : "Dependencies unverified"
                value = "#{row[:entries].size} rules, #{policy}"
              end
              [ row[:vlan] || row[:interface] || "shared", display_fabric_value(value) ]
            end
            grouped.each do |(vlan, value), members|
              names = members.map { |row| row[:name] || by_host.dig(row[:host], "target", "name") || row[:host] }
              lines.concat([ "  VLAN/interface #{vlan}: #{value}", "    #{names.join(', ')}" ])
            end
            if evidence.any? { |row| row[:semantics] }
              evidence.group_by { |row| row[:semantics] }.each_with_index do |(rules, members), variant|
                lines << "  Rule version #{variant + 1}: #{members.map { |row| by_host.dig(row[:host], 'target', 'name') || row[:host] }.join(', ')}"
                lines.concat(rules.map { |rule| "    #{rule['action']} #{rule['expression']}" })
              end
            end
          end
          lines.join("\n") + "\n"
        end

        # 机器字段转换为运维读法，显式保留缺失和未知。
        def display_fabric_value(value)
          if value.is_a?(Hash) && value.key?(:acl)
            return "No ACL attached" unless value[:acl]
            return "#{value[:acl]}; local definition missing" unless value[:defined]
            return "#{value[:acl]}; defined, but dependencies unverified" unless value[:policy_verified]
            "#{value[:acl]}; defined, version #{value[:digest].to_s[0, 12]}"
          elsif value.is_a?(Array)
            value.empty? ? "No address configured" : value.join(", ")
          elsif value.nil?
            "not provided"
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
            [ File.expand_path(path), body, JSON.parse(body, max_nesting: 128) ]
          end
          build_review(sources, policy: policy, standalone: false) unless sources.empty?
        end
      end
    end
  end
end
