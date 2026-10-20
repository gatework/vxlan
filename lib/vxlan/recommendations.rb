# frozen_string_literal: true

require_relative "cisco_nxos/profile"
require_relative "config/evidence"

module Vxlan
  # 对持久化事实生成可审阅建议；不持有连接器，不下发配置，不推断跨设备 Fabric 归属。
  class Recommendations
    REFERENCE = "https://www.cisco.com/c/en/us/td/docs/dcn/nx-os/nexus9000/103x/configuration/vxlan/cisco-nexus-9000-series-nx-os-vxlan-configuration-guide-release-103x/m_configuring_vxlan_bgp_evpn.html"
    TITLES = {
      "vlan_vni_without_nve" => "VLAN 已映射 VNI，但缺少 NVE 成员",
      "nve_l2_without_vlan" => "L2 NVE 成员缺少 VLAN 映射",
      "nve_l2_without_evpn" => "L2 NVE 成员缺少 EVPN 配置",
      "nve_l3_without_vrf" => "L3 NVE 成员缺少 VRF 关联",
      "evpn_vni_without_nve" => "EVPN VNI 缺少 NVE 成员",
      "vni_layer_conflict" => "VNI 的 L2/L3 属性冲突",
      "l3_vni_without_nve" => "VRF VNI 缺少 NVE 成员"
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
      @dimensions = document.dig("snapshot", "dimensions") || {}
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
      { schema_version: 1, review_only: true, health_assessment: "not_performed", device: @document["device"],
        observed_at: @document.dig("snapshot", "observed_at"), items: items, counts: items.map { |item| item[:status] }.tally }
    end

    private

    # 无 VNI、无网关的残留接口也保留悬空引用，不能由共同业务筛选掩盖。
    def undefined_acl_items(config)
      config.fetch("interfaces", {}).flat_map do |name, interface|
        interface.fetch("acl_bindings", {}).filter_map do |direction, acl|
          next if config.fetch("acls", {}).key?(acl)
          result = item("acl_reference_undefined", "#{name} / #{direction}", "接口引用 ACL #{acl}，本机缺少定义",
            evidence: { interface: name, direction: direction, acl: acl, addresses: interface.fetch("addresses", []), vlan_vni: config.fetch("vlan_vnis", {})[name.delete_prefix("Vlan")] },
            verify: [ "show running-config", "show ip interface brief vrf all" ])
          result[:blockers] << "先确认接口是否承载业务及 ACL 的权威定义；无地址或无 VNI 可能是残留配置，不能直接推断业务中断，也不能按名称复制其他 Fabric 的 ACL。"
          result[:impact] = "新增 ACL 定义会作用于本机所有同名引用；须核对全部引用及回退范围。"
          result[:references] = []
          result
        end
      end
    end

    # 建议只保存有关事实，不复制整份配置或敏感命令正文。
    def item(code, scope, title, evidence:, verify:, category: "configuration")
      { code: code, scope: scope, title: title, category: category, status: "blocked", evidence: evidence,
        prerequisites: [], blockers: [], commands: [], rollback: [], verify: verify,
        expected: "重新采集并核对该项事实；业务连通性须另行验收。", references: [ REFERENCE ] }
    end

    # 仅在完整配置证实关联缺失时讨论增量补齐，不自动删除疑似闲置配置。
    def configuration_item(config, finding)
      vni = finding["vni"]
      result = item(finding["code"], "VNI #{vni}", TITLES.fetch(finding["code"], "配置关联需要核查"),
        evidence: finding, verify: [ "show running-config", "show nve vni", "show nve peers", "show bgp l2vpn evpn summary" ])
      result[:vni] = vni
      result[:prerequisites] = [ "确认该 VNI 应在本机承载业务，而非预配置或退网残留。", "核对当前软件版本、设备角色、同 Fabric 对端的 VLAN/VNI、RD/RT 与复制方式。", "重新采集配置并确认与本报告一致；审批维护窗口后逐台操作，出现异常先回读，勿盲目重放。" ]
      result[:impact] = "补齐可能开始发布路由或扩展二层广播域；须核对隔离边界、对端配置和回退条件。"
      result[:expected] = "VLAN、NVE 与 EVPN 关联一致；预期承载业务的 VNI 状态 Up，BGP/对端正常，业务验收通过。"
      unless vni.is_a?(Integer) && vni.between?(1, 16_777_215)
        result[:blockers] << "VNI 非有效整数，无法生成命令。"
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
          candidate(result, evpn_add(vni), evpn_remove(vni), "本机现有 L2 EVPN 均采用 RD auto、RT import/export auto；候选沿用此模式，仍需确认本 VNI 的业务意图。")
        else
          result[:blockers] << "需要唯一 VLAN 映射、L2 BGP 复制以及一致的 RD/RT 策略；缺失或冲突时不能套用 auto。"
        end
      when "vlan_vni_without_nve", "evpn_vni_without_nve"
        if l2_context?(config, vni, vlans) && !member && bgp_replication?(nve) && (evpn ? auto_evpn?(evpn) : auto_policy?(config))
          commands = [ "interface #{nve['interface']}", "  member vni #{vni}", "    ingress-replication protocol bgp", "exit", "exit" ]
          rollback = [ "interface #{nve['interface']}", "  no member vni #{vni}", "exit" ]
          commands.concat(evpn_add(vni)) unless evpn
          rollback.concat(evpn_remove(vni)) unless evpn
          candidate(result, commands, rollback, "本机既有 L2 成员统一使用 BGP 复制、EVPN auto 策略；仅补齐缺失的 NVE/EVPN，不启用额外 ARP 抑制。")
        else
          result[:blockers] << "需确认 VNI 的 L2/L3 角色、VLAN、NVE 接口、复制模式和 RD/RT，当前不能唯一确定增量配置。"
        end
      when "nve_l2_without_vlan"
        result[:blockers] << "请提供本 VNI 对应 VLAN ID，并核对 access/trunk/SVI；不能由 VNI 尾数或其他设备名称猜测。"
        result[:template] = [ "vlan <VLAN_ID>", "  vn-segment #{vni}" ]
      else
        result[:blockers] << "需要明确 VRF/VNI 业务映射和 L2/L3 角色；先核对设计，再补齐或清理残留配置。"
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
        item("evidence_incomplete", name, "证据不完整，先补采", evidence: evidence,
          verify: Array(CiscoNxos::Profile::COMMANDS[name.to_sym]), category: "evidence").merge(status: "investigate", expected: "完整回显或明确的零记录证明；空响应不能等同无配置。")
      end
    end

    # 运行异常只生成定位建议；Down 也可能是计划停用，不能自动 no shutdown。
    def runtime_tasks
      %w[nve_vnis nve_peers bgp_neighbors].filter_map do |dimension|
        rows = @dimensions.fetch(dimension, {}).fetch("records", []).select { |row| %w[down idle active connect opensent openconfirm].include?(row["state"].to_s.downcase) }
        next if rows.empty?
        item("#{dimension}_not_up", dimension, "观测到未建立的运行状态", evidence: rows,
          verify: [ CiscoNxos::Profile::COMMANDS[dimension.to_sym], "show running-config" ], category: "runtime").merge(status: "investigate", prerequisites: [ "先确认业务预期，再检查对端、底层路由、接口和配置；不自动重启邻居或启用接口。" ])
      end
    end
  end
end
