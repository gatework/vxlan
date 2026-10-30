# frozen_string_literal: true

require "ctx_runner/evidence"
require_relative "cisco_nxos/profile"
require_relative "config/evidence"

module Vxlan
  # 对持久化事实生成可审阅建议；不持有连接器，不下发配置，不推断跨设备 Fabric 归属。
  class Recommendations
    REFERENCE = "https://www.cisco.com/c/en/us/td/docs/dcn/nx-os/nexus9000/103x/configuration/vxlan/cisco-nexus-9000-series-nx-os-vxlan-configuration-guide-release-103x/m_configuring_vxlan_bgp_evpn.html"
    TITLES = {
      "vlan_vni_without_nve" => "VLAN maps to a VNI but the NVE member is missing",
      "nve_l2_without_vlan" => "L2 NVE member lacks a VLAN mapping",
      "nve_l2_without_evpn" => "L2 NVE member lacks EVPN configuration",
      "nve_l3_without_vrf" => "L3 NVE member lacks a VRF association",
      "evpn_vni_without_nve" => "EVPN VNI lacks an NVE member",
      "vni_layer_conflict" => "VNI has conflicting L2/L3 attributes",
      "l3_vni_without_nve" => "VRF VNI lacks an NVE member"
    }.freeze

    # 联合证据可以解决本机未知，但角色冲突优先阻断所有草稿；不改变原始发现。
    def self.combine(local, supplemental)
      supplemental = Array(supplemental)
      resolved = supplemental.select { |item| item[:status] == "candidate" }.flat_map { |item| item.fetch(:resolves, []) }
      items = local[:items].reject { |item| resolved.include?(item.slice(:code, :vni)) } + supplemental
      conflict = supplemental.find { |item| item[:code] == "fabric_role_conflict" }
      if conflict
        items = items.map do |item|
          next item unless item[:status] == "candidate"
          item.reject { |key, _| key == :change }.merge(status: "blocked", commands: [], rollback: [], blockers: item.fetch(:blockers, []) + conflict[:blockers])
        end
      end
      local.merge(items: items, counts: items.map { |item| item[:status] }.tally)
    end

    # 输入为报告 JSON 的字符串键结构，离线与实时报告共用此边界。
    def initialize(document)
      @document = document
      @dimensions = document.dig("snapshot", "observations") || {}
    end

    # 建议与采集完整性分开；没有命中规则并不代表网络健康。
    def call
      items = evidence_tasks
      config = Config::Evidence.complete_record(@document)
      if config
        items.concat(config.fetch("review_findings", []).map { |finding| configuration_item(config, finding) })
        items.concat(undefined_acl_items(config))
      end
      items.concat(runtime_tasks)
      { schema_version: CtxRunner::Evidence::VERSION, kind: "recommendations", review_only: true, health_assessment: "not_performed", target: @document["target"],
        observed_at: @document.dig("snapshot", "observed_at"), items: items, counts: items.map { |item| item[:status] }.tally }
    end

    private

    # 无 VNI、无网关的残留接口也保留悬空引用，不能由共同业务筛选掩盖。
    def undefined_acl_items(config)
      config.fetch("interfaces", {}).flat_map do |name, interface|
        interface.fetch("acl_bindings", {}).filter_map do |direction, acl|
          next if config.fetch("acls", {}).key?(acl)
          result = item("acl_reference_undefined", "#{name} / #{direction}", "Interface references ACL #{acl}, but its local definition is missing",
            evidence: { interface: name, direction: direction, acl: acl, addresses: interface.fetch("addresses", []), vlan_vni: config.fetch("vlan_vnis", {})[name.delete_prefix("Vlan")] },
            verify: [ "show running-config", "show ip interface brief vrf all" ])
          result[:blockers] << "First confirm whether the interface carries a service and identify the authoritative ACL definition; missing addresses or VNIs may be residual configuration. Do not infer a service outage or copy another Fabric's ACL by name."
          result[:impact] = "Adding an ACL definition affects all local references to that name; verify every reference and the rollback scope."
          result[:references] = []
          result
        end
      end
    end

    # 建议只保存有关事实，不复制整份配置或敏感命令正文。
    def item(code, scope, title, evidence:, verify:, category: "configuration")
      { code: code, scope: scope, title: title, category: category, status: "blocked", evidence: evidence,
        prerequisites: [], blockers: [], commands: [], rollback: [], verify: verify,
        expected: "Collect again and verify this fact; service connectivity requires separate acceptance.", references: [ REFERENCE ] }
    end

    # 仅在完整配置证实关联缺失时讨论增量补齐，不自动删除疑似闲置配置。
    def configuration_item(config, finding)
      vni = finding["vni"]
      result = item(finding["code"], "VNI #{vni}", TITLES.fetch(finding["code"], "Configuration associations require verification"),
        evidence: finding, verify: [ "show running-config", "show nve vni", "show nve peers", "show bgp l2vpn evpn summary" ])
      result[:vni] = vni
      result[:prerequisites] = [ "Confirm that this VNI should carry a service locally, rather than being staged configuration or a decommissioning remnant.", "Check the current software version, device role, and same-Fabric peers' VLAN/VNI, RD/RT and replication mode.", "Collect configuration again and verify it matches this report; after maintenance window approval, operate one device at a time. On anomalies, read back first and avoid blind replay." ]
      result[:impact] = "Completing the configuration may start route advertisement or extend the L2 broadcast domain; verify isolation boundaries, peer configuration and rollback conditions."
      result[:expected] = "VLAN, NVE and EVPN associations are consistent; VNIs expected to carry services are Up, BGP/peers are healthy, and service acceptance passes."
      unless vni.is_a?(Integer) && vni.between?(1, 16_777_215)
        result[:blockers] << "VNI is not a valid integer; commands cannot be generated."
        return result
      end
      vlans = config.fetch("vlan_vnis", {}).select { |_vlan, mapped| mapped == vni }.keys
      nve = config.fetch("nve", {})
      member = nve.fetch("members", {})[vni.to_s]
      evpn = config.fetch("evpn", {})[vni.to_s]
      result[:evidence] = finding.merge("vlan_ids" => vlans, "nve_member" => member, "evpn" => evpn)
      case finding["code"]
      when "nve_l2_without_evpn"
        if l2_context?(config, vni, vlans) && member && member["associate_vrf"] == false && member["replication"] == "bgp" && !evpn && auto_policy?(config)
          candidate(result, evpn_add(vni), evpn_remove(vni), "All existing local L2 EVPN instances use RD auto and RT import/export auto; the candidate follows this pattern, but the service intent of this VNI still requires confirmation.")
        else
          result[:blockers] << "A unique VLAN mapping, L2 BGP replication and consistent RD/RT policy are required; missing or conflicting evidence does not permit applying auto."
        end
      when "vlan_vni_without_nve", "evpn_vni_without_nve"
        if l2_context?(config, vni, vlans) && !member && bgp_replication?(nve) && (evpn ? auto_evpn?(evpn) : auto_policy?(config))
          commands = [ "interface #{nve['interface']}", "  member vni #{vni}", "    ingress-replication protocol bgp", "exit", "exit" ]
          rollback = [ "interface #{nve['interface']}", "  no member vni #{vni}", "exit" ]
          commands.concat(evpn_add(vni)) unless evpn
          rollback.concat(evpn_remove(vni)) unless evpn
          candidate(result, commands, rollback, "Existing local L2 members uniformly use BGP replication and EVPN auto policy; complete only missing NVE/EVPN configuration, without enabling additional ARP suppression.")
        else
          result[:blockers] << "Confirm the VNI's L2/L3 role, VLAN, NVE interface, replication mode and RD/RT; a unique configuration change cannot currently be determined."
        end
      when "nve_l2_without_vlan"
        result[:blockers] << "Provide the VLAN ID for this VNI and verify access/trunk/SVI configuration; do not infer it from VNI suffixes or other device names."
        result[:template] = [ "vlan <VLAN_ID>", "  vn-segment #{vni}" ]
      else
        result[:blockers] << "An explicit VRF/VNI service mapping and L2/L3 role are required; verify the design before completing or removing residual configuration."
      end
      result
    end

    # 同一 VNI 只能有一个有效 VLAN，且不能同时属于 VRF。
    def l2_context?(config, vni, vlans)
      nve = config.fetch("nve", {})
      config["nv_overlay_evpn"] == true && nve["shutdown"] == false && nve["host_reachability"] == "bgp" &&
        nve["interface"].to_s.match?(/\Anve[1-9]\d*\z/i) && vlans.size == 1 && vlans.first.match?(/\A\d+\z/) && vlans.first.to_i.between?(1, 4094) &&
        config.fetch("vrfs", {}).values.none? { |vrf| vrf["vni"] == vni }
    end

    # 仅识别本机全部 L2 EVPN 都使用显式 auto 的情况，不推断跨 ASN 策略。
    def auto_policy?(config)
      policies = config.fetch("evpn", {}).values.select { |settings| settings["type"] == "l2" }
      policies.any? && policies.all? { |settings| auto_evpn?(settings) }
    end

    # 正反方向必须同时存在且没有额外定制 RT。
    def auto_evpn?(settings)
      targets = settings.fetch("route_targets", [])
      settings["type"] == "l2" && settings["rd"] == "auto" && targets.size == 2 &&
        targets.map { |rt| rt["direction"] }.sort == %w[export import] &&
        targets.all? { |rt| rt["target"] == "auto" && rt["evpn"] == false }
    end

    # 混合组播或静态复制时不生成 BGP 复制候选。
    def bgp_replication?(nve)
      members = nve.fetch("members", {}).values.reject { |settings| settings["associate_vrf"] }
      members.any? && members.all? { |settings| settings["replication"] == "bgp" && !settings["multicast_group"] }
    end

    # NX-OS L2 EVPN 子模式增量；不包含保存配置命令。
    def evpn_add(vni)
      [ "evpn", "  vni #{vni} l2", "    rd auto", "    route-target import auto", "    route-target export auto", "exit", "exit" ]
    end

    # 只删除本候选新增的子节点，保留既有全局配置。
    def evpn_remove(vni) = [ "evpn", "  no vni #{vni} l2", "exit" ]

    # 候选仍需人工确认业务意图，不能作为自动变更许可。
    def candidate(result, commands, rollback, assumption)
      result[:status] = "candidate"
      result[:prerequisites] << assumption
      result[:commands] = [ "configure terminal", *commands, "end" ]
      result[:rollback] = [ "configure terminal", *rollback, "end" ]
    end

    # 空或部分证据只生成重新采集任务，不按缺失配置处理。
    def evidence_tasks
      selected = @dimensions.reject { |name, _| name == "collection" }
      selected = { "configuration" => { "status" => "not_requested" } } if selected.empty?
      selected.filter_map do |name, observation|
        next if observation["status"] == "complete" && (name != "configuration" || Config::Evidence.complete_record(@document))
        evidence = { status: observation["status"], issues: observation.fetch("issues", []).map { |issue| issue["code"] } }
        if name == "configuration"
          records = observation.fetch("records", [])
          evidence.merge!(configuration_records: records.size, review_status: records.map { |record| record["review_status"] })
        end
        item("evidence_incomplete", name, "Evidence incomplete; collect missing evidence first", evidence: evidence,
          verify: Array(CiscoNxos::Profile::DECLARATIONS.by_dimension[name.to_sym]), category: "evidence").merge(status: "investigate", expected: "A complete response or explicit zero-record evidence is required; an empty response does not establish absence of configuration.")
      end
    end

    # 运行异常只生成定位建议；Down 也可能是计划停用，不能自动 no shutdown。
    def runtime_tasks
      %w[nve_vnis nve_peers bgp_neighbors].filter_map do |dimension|
        rows = @dimensions.fetch(dimension, {}).fetch("records", []).select { |row| %w[down idle active connect opensent openconfirm].include?(row["state"].to_s.downcase) }
        next if rows.empty?
        item("#{dimension}_not_up", dimension, "Observed runtime state is not established", evidence: rows,
          verify: [ CiscoNxos::Profile::DECLARATIONS.by_dimension[dimension.to_sym], "show running-config" ], category: "runtime").merge(status: "investigate", prerequisites: [ "Confirm service expectations first, then check peers, underlay routing, interfaces and configuration; do not automatically restart neighbors or enable interfaces." ])
      end
    end
  end
end
