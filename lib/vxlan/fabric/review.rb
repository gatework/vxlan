# frozen_string_literal: true

require "ipaddr"
require "json"
require "digest"
require_relative "../change_plan"
require_relative "../acl_policy"
require_relative "scope"
require_relative "../service/catalog"
require_relative "../service/mapping"
require_relative "../config/evidence"
require_relative "../subnet_index"

module Vxlan
  module Fabric
    # 显式 Fabric 边界内比较已部署业务；设备角色和部署范围不由多数票推导。
    class Review
      # 比较范围由业务策略统一验证，审查器只负责组织规则与建议。
      def initialize(documents, policy)
        @documents = documents.to_h { |document| [ document.fetch("device").fetch("host"), document ] }
        raise ArgumentError, "重复设备身份" unless @documents.size == documents.size
        @scope = Scope.new(policy)
      end

      # 缺少任何成员的完整配置时仍报告覆盖，但不据此生成跨设备增量。
      def call
        @findings, @items, @coverage, @subnet_indexes = [], Hash.new { |hash, host| hash[host] = [] }, [], {}
        inventory = @scope.coverage(@documents.keys)
        finding("未归属", nil, "fabric_scope_unassigned", "已采集设备未纳入 Fabric 策略，跨设备审查未覆盖", inventory[:unassigned]) if inventory[:unassigned].any?
        @scope.groups.each do |fabric, group|
          configs = group.values.flatten.to_h { |host| [ host, configuration(host) ] }
          unknown = configs.select { |_host, config| config.nil? }.keys
          unless unknown.empty?
            finding(fabric, nil, "fabric_evidence_incomplete", "成员配置证据不完整，停止该 Fabric 的变更推导", unknown)
            next
          end
          %w[leaves borders].each do |role|
            @role = role
            review_group(fabric, configs.slice(*group[role]), all_configs: configs) if group[role].any?
          end
          @role = "spines"
          group["spines"].each { |host| review_spine(fabric, host, configs.fetch(host)) }
          @role = nil
          review_subnets(fabric, configs)
        end
        { schema_version: 2, scope: "same_role_same_deployed_vni", inventory: inventory, findings: @findings, device_items: @items.to_h, coverage: @coverage }
      end

      private

      # 配置完整性是关联缺失和规则对比的前提，运行表部分不影响完整配置比较。
      def configuration(host)
        Config::Evidence.complete_record(@documents[host])
      end

      # 每个 VNI 只纳入已映射此业务的 Leaf，未部署的 Leaf 仅记录覆盖范围。
      def review_group(fabric, configs, all_configs:)
        services = Service::Catalog.new(configs).services
        policies = configs.transform_values do |config|
          config.fetch("acls", {}).transform_values { |entries| AclPolicy.resolve(config, entries) }
        end
        services.sort.each do |vni, rows|
          @coverage << { fabric: fabric, role: @role, vni: vni, deployed: rows.map { |row| row[:host] }.uniq, not_deployed: configs.keys - rows.map { |row| row[:host] }, incomplete: rows.select { |row| row[:missing].any? }.map { |row| row[:host] }.uniq }
          incomplete = rows.select { |row| row[:missing].any? }
          if incomplete.any?
            finding(fabric, vni, "fabric_service_incomplete", "业务已开始部署，但 VLAN/NVE/EVPN 关联不完整", observations(incomplete) { |row| { missing: row[:missing] } })
            review_missing_mappings(fabric, vni, rows, all_configs)
          end
          if rows.map { |row| row[:host] }.uniq.size != rows.size
            finding(fabric, vni, "fabric_vlan_mapping_ambiguous", "同一 Leaf 将多个 VLAN 映射到相同 VNI", rows.map { |row| row.slice(:host, :vlan) })
            next
          end
          next unless rows.size >= 2
          constraints = review_transport(fabric, vni, rows)
          service_blocked = incomplete.any? || constraints
          # 缺映射行没有可定位 SVI，不能再扩散为网关、MTU 等一串伪差异。
          rows = rows.select { |row| row[:vlan] }
          next unless rows.size >= 2
          compare(fabric, vni, "fabric_vlan_mapping", "相同 VNI 的本地 VLAN 编号不一致", rows) { |row| row[:vlan] }
          # L2 业务没有网关可以是正常设计，但仍须检查承载与控制平面。
          next unless rows.any? { |row| row[:svi] && (row[:svi]["anycast"] || row[:svi].fetch("addresses", []).any?) }
          review_gateway(fabric, vni, rows, all_configs, service_blocked: service_blocked)
          %w[in out].each { |direction| review_acl(fabric, vni, rows, direction, policies: policies, service_blocked: service_blocked) }
          %w[vrf anycast mtu shutdown].each do |field|
            compare(fabric, vni, "fabric_#{field}", "业务 SVI 的 #{field} 不一致", rows) { |row| row[:svi]&.fetch(field, nil) }
          end
          compare(fabric, vni, "fabric_anycast_mac", "Anycast 网关 MAC 不一致", rows) { |row| row[:config]["anycast_mac"] }
        end
        review_acl_catalog(fabric, configs, policies)
        review_address_groups(fabric, configs)
      end

      # 已有 NVE/EVPN 的缺映射业务单独推导，不把不完整关联当作从未部署。
      def review_missing_mappings(fabric, vni, rows, configs)
        rows.select { |row| row[:missing] == [ "VLAN" ] }.each do |row|
          evidence = observations(rows) { |peer| { missing: peer[:missing], gateway: peer[:svi]&.fetch("addresses", []), vrf: peer[:svi]&.dig("vrf") } }
          item = recommendation(fabric, vni, "fabric_vlan_mapping_missing", "补齐已有业务的 VLAN/VNI 关联", evidence)
          plan = Service::Mapping.infer(vni, row, rows)
          change = plan&.to_h
          conflicts = change ? gateway_conflicts(configs, change, except: [ row[:host], "Vlan#{change['vlan']}" ]) : []
          if conflicts.any?
            item[:evidence].concat(conflicts)
            item[:blockers] << "同 VRF 存在跨 SVI/跨 VNI 网段重叠，不能通过新增映射扩大冲突：#{conflicts.map { |entry| "#{entry[:name]} #{entry[:interface]}" }.join('、')}"
            plan = nil
          end
          if plan
            local_svi = row[:config].fetch("interfaces").fetch("Vlan#{change['vlan']}")
            item[:evidence] = evidence.map do |entry|
              entry[:host] == row[:host] ? entry.merge(vlan: change["vlan"].to_s, value: { missing: [ "VLAN/VNI 映射" ], gateway: local_svi["addresses"], vrf: local_svi["vrf"] }) : entry
            end
            item[:impact] = "将已有 VLAN 接入既有 VXLAN 业务，可能立即扩展广播域；不创建 VLAN，不更改网关或 ACL。"
            item[:prerequisites] << "本机未映射 VLAN 的网关、VRF、Anycast 身份及 ACL 与完整对端一致，NVE/EVPN 也已匹配；确认该业务确应在本机接入。"
            item[:expected] = "本机 VLAN/VNI 关联完整、VNI 状态符合预期，既有网关及 ACL 保持不变；接入业务验收通过。"
            item[:resolves] = [ { code: "nve_l2_without_vlan", vni: vni } ]
            propose(item, plan, service_blocked: false)
          else
            item[:blockers] << "没有唯一且完整的业务对应关系；需核对本机未映射 VLAN、网关、VRF、ACL 与对端配置，禁止按 VNI 数值猜测 VLAN。"
          end
          @items[row[:host]] << item
        end
      end

      # 一致性约束先于增量生成；承载/路由声明冲突时停止叠加网关和 ACL 变更。
      def review_transport(fabric, vni, rows)
        before = @findings.size
        compare(fabric, vni, "fabric_replication", "NVE 复制方式或组播组声明不一致", rows) { |row| Service::Catalog.nve_member(row[:config], row[:nve])&.slice("replication", "multicast_group") }
        compare(fabric, vni, "fabric_arp_suppression", "ARP 抑制的显式配置不一致", rows) { |row| row[:nve]&.fetch("suppress_arp", nil) }
        compare(fabric, vni, "fabric_route_targets", "EVPN 导入/导出 RT 声明不一致，需核对路由互通与隔离", rows) do |row|
          row[:evpn] && Service::Catalog.route_targets(row[:evpn]["route_targets"], asn: row[:config].dig("bgp", "asn"), vni: vni)
        end
        tenant_rows = rows.select { |row| row[:svi] && row[:svi]["vrf"] }
        compare(fabric, vni, "fabric_tenant_routing", "共同业务的租户 VNI 或路由导入/导出声明不一致", tenant_rows) do |row|
          Service::Catalog.tenant(row[:config], row[:svi]["vrf"])
        end if tenant_rows.size >= 2
        @findings.size > before
      end

      # Spine 角色的业务承载配置保留为待决项，不能自动补齐或删除疑似残留。
      def review_spine(fabric, host, config)
        services = Service::Catalog.new(host => config).services
        return if services.empty?
        evidence = [ { host: host, value: { role: "spines", l2_vnis: services.keys.sort } } ]
        finding(fabric, nil, "fabric_role_conflict", "声明为 Spine，但存在 L2 业务承载配置", evidence)
        item = recommendation(fabric, nil, "fabric_role_conflict", "核对 Spine 是否应承担业务 VTEP 职责", evidence)
        item[:blockers] << "先确认角色或迁移残留；不能因为出现 NVE 就自动把 Spine 当作 Leaf，不能自动补业务配置或删除 NVE。"
        @items[host] << item
      end

      # 网关不一致与地址迁移分开；未知目标不做替换，仅允许无冲突的缺失地址补齐。
      def review_gateway(fabric, vni, rows, configs, service_blocked:)
        values = rows.map { |row| row[:svi]&.fetch("addresses", [])&.sort }
        return if values.uniq.one?
        finding(fabric, vni, "fabric_gateway", "同业务网关地址不一致", observations(rows) { |row| row[:svi]&.fetch("addresses", []) })
        expected = values.compact.reject(&:empty?).uniq
        rows.each do |row|
          next if expected.one? && row[:svi]&.fetch("addresses", [])&.sort == expected.first
          item = recommendation(fabric, vni, "fabric_gateway", "网关地址需要一致", observations(rows) { |entry| entry[:svi]&.fetch("addresses", []) })
          change = { "kind" => "svi_gateway_add", "vlan" => row[:vlan].to_i, "vni" => vni, "vrf" => row[:svi]&.dig("vrf"), "address" => expected.one? && expected.first.one? ? expected.first.first : nil }
          context = rows.map { |entry| [ entry[:svi]&.dig("vrf"), entry[:svi]&.dig("anycast"), entry[:config]["anycast_mac"] ] }.uniq
          conflicts = change["address"] ? gateway_conflicts(configs, change) : []
          item[:evidence].concat(conflicts)
          if conflicts.empty? && context.one? && context.first.all? && expected.one? && expected.first.one? &&
              (plan = ChangePlan.candidate(change, config: row[:config]))
            propose(item, plan, service_blocked: service_blocked)
          else
            item[:blockers] << "存在已有地址、跨 SVI/跨 VNI 网段冲突，或 VRF/Anycast 模式/MAC 不一致、缺少唯一网关；需先确认迁移设计，禁止重复添加网关。"
            item[:blockers] << "Fabric 内冲突接口：#{conflicts.map { |conflict| "#{conflict[:name]} #{conflict[:interface]}" }.join('、')}" if conflicts.any?
          end
          @items[row[:host]] << item
        end
      end

      # 目标机没有重复地址还不够；其他 Leaf 的跨 VNI 重叠同样阻止扩散网关。
      def gateway_conflicts(configs, change, except: nil)
        configs.flat_map do |host, config|
          index = (@subnet_indexes[host] ||= SubnetIndex.new(config))
          excluded = except&.first == host ? except.last : nil
          index.conflicts(address: change["address"], vrf: change["vrf"], vni: change["vni"], except_interface: excluded).map do |entry|
            { host: host, name: @documents[host]["device"]["name"], **entry }
          end
        end
      end

      # 无 ACL 不构成删除保护的基线；只从一致且已实际挂载的访问控制提出补齐。
      def review_acl(fabric, vni, rows, direction, policies:, service_blocked:)
        bindings = rows.map { |row| row[:svi]&.dig("acl_bindings", direction) }
        definitions = rows.map { |row| name = row[:svi]&.dig("acl_bindings", direction); name && policies.dig(row[:host], name) }
        different_binding = bindings.uniq.size > 1
        different_content = definitions.uniq.size > 1 || bindings.zip(definitions).any? { |name, content| name && content.nil? }
        return unless different_binding || different_content
        evidence = observations(rows) do |row|
          name = row[:svi]&.dig("acl_bindings", direction)
          entries = name && row[:config].fetch("acls", {})[name]
          policy = policies.dig(row[:host], name)
          { acl: name, defined: !entries.nil?, entries: entries, policy_verified: !policy.nil?, address_groups: policy&.address_groups, digest: policy && CtxRunner::Fingerprint.call(policy.to_h) }
        end
        code = different_binding ? "fabric_acl_binding" : "fabric_acl_content"
        finding(fabric, vni, code, "#{direction} 方向 ACL 挂载/有序规则不一致", evidence)
        undefined = evidence.select { |row| row[:value][:acl] && !row[:value][:defined] }
        finding(fabric, vni, "fabric_acl_undefined", "#{direction} 方向已挂载 ACL，但本机没有对应定义", undefined) if undefined.any?
        unresolved = evidence.select { |row| row[:value][:defined] && !row[:value][:policy_verified] }
        finding(fabric, vni, "fabric_acl_dependency", "#{direction} 方向 ACL 依赖对象缺失、为空或尚未解析，不能证明策略一致", unresolved) if unresolved.any?
        names = bindings.compact.uniq
        sources = rows.select { |row| row[:config].fetch("acls", {})[names.first] }
        originals = sources.map { |row| row[:config]["acls"][names.first] }
        unique = sources.map { |row| policies.dig(row[:host], names.first) }.uniq
        rows.each do |row|
          current_name = row[:svi]&.dig("acl_bindings", direction)
          current_entries = names.one? && row[:config].fetch("acls", {})[names.first]
          next if names.one? && unique.one? && unique.first && current_name == names.first && policies.dig(row[:host], names.first) == unique.first
          item = recommendation(fabric, vni, code, "统一 #{direction} 方向访问控制", evidence)
          change = { "kind" => "svi_acl", "vlan" => row[:vlan].to_i, "vni" => vni, "direction" => direction,
            "acl" => names.first, "entries" => originals.first, "create_acl" => current_entries.nil?, "previous_binding" => current_name }
          change["address_groups"] = unique.first.address_groups if unique.one? && unique.first
          context_matches = rows.map { |entry| entry[:svi]&.dig("vrf") }.uniq.one?
          if names.one? && unique.one? && unique.first && context_matches &&
              (plan = ChangePlan.candidate(change, config: row[:config]))
            item[:prerequisites] << "依据是本业务已挂载且有序内容一致的 ACL；即使挂载节点较少，也不以无 ACL 的多数节点为删除依据。确认此业务应统一受该 ACL 保护。"
            propose(item, plan, service_blocked: service_blocked)
          else
            item[:blockers] << "ACL 名称、有序规则、地址组成员、VRF 或当前绑定不能证明一致；需选择权威规则及完整依赖，不自动覆盖或撤销访问控制。"
            shared = change["create_acl"] ? AclPolicy.bindings(row[:config], names.first) - [ { "interface" => "Vlan#{row[:vlan]}", "direction" => direction } ] : []
            if shared.any?
              references = shared.map { |binding| "#{binding['interface']} #{binding['direction']}" }.join("、")
              item[:blockers] << "创建 #{names.first} 还会激活既有引用：#{references}。需合并所有受影响接口核对策略和回退，禁止作为单个 SVI 的补齐执行。"
            end
          end
          @items[row[:host]] << item
        end
      end

      # 同名 ACL 即使暂未挂载也报告规则债务，避免未来补挂时激活不同策略。
      def review_acl_catalog(fabric, configs, policies)
        names = configs.values.flat_map { |config| config.fetch("acls", {}).keys }.uniq.sort
        names.each do |name|
          rows = configs.filter_map do |host, config|
            entries = config.fetch("acls", {})[name]
            { host: host, entries: entries, semantics: policies.dig(host, name)&.rules || AclPolicy.rules(entries), policy: policies.dig(host, name)&.to_h } if entries
          end
          if rows.map { |row| row[:semantics] }.uniq.size > 1 || rows.map { |row| row[:policy] }.uniq.size > 1
            finding(fabric, nil, "fabric_acl_content", "同名 ACL #{name} 的有序规则或依赖对象不同（包括尚未挂载的定义）", rows)
          end
          unknown = rows.select { |row| row[:policy].nil? }
          finding(fabric, nil, "fabric_acl_dependency", "ACL #{name} 的依赖对象未验证，不能证明策略一致（包括尚未挂载的定义）", unknown) if unknown.any?
        end
      end

      # 展开引用对象的成员差异，避免只展示相同的 ACL 文本而隐藏实际匹配范围。
      def review_address_groups(fabric, configs)
        # 每台设备的引用去重后直接归入对象索引，避免每个对象再扫描所有引用。
        references = {}
        configs.each do |host, config|
          names = config.fetch("acls", {}).values.flatten.flat_map { |entry| entry["expression"].scan(/\baddrgroup\s+(\S+)/).flatten }.uniq
          names.each { |name| (references[name] ||= []) << { host: host, value: config.fetch("address_groups", {})[name] } }
        end
        references.sort.each do |name, rows|
          next unless rows.map { |row| row[:value] }.uniq.size > 1
          finding(fabric, nil, "fabric_address_group", "ACL 地址组 #{name} 成员不同或缺失；仅比较引用此对象的业务，不自动复制", rows)
        end
      end

      # 同 VRF 内按规范网段区间扫描，保留跨 VNI 的包含关系；同网段多台证据先合并。
      def review_subnets(fabric, configs)
        subnets = Hash.new { |hash, key| hash[key] = [] }
        configs.each do |host, config|
          config.fetch("interfaces", {}).each do |name, svi|
            next unless name.match?(/\AVlan\d+\z/) && svi["anycast"]
            vni = config.fetch("vlan_vnis", {})[name.delete_prefix("Vlan")]
            next unless vni
            svi.fetch("addresses", []).each do |address|
              network = IPAddr.new(address)
              subnets[[ svi["vrf"], network.ipv4?, network.to_i, network.to_range.last.to_i ]] << { host: host, interface: name, vni: vni, address: address }
            end
          end
        end
        subnets.group_by { |(vrf, ipv4, _start, _finish), _rows| [ vrf, ipv4 ] }.each do |(vrf, _ipv4), networks|
          active = []
          networks.sort_by { |(key, _rows)| key[2] }.each do |key, rows|
            active.reject! { |other_key, _other_rows| other_key[3] < key[2] }
            conflicts = active.filter_map do |_other_key, other_rows|
              combined = other_rows + rows
              combined if combined.map { |row| row[:vni] }.uniq.size > 1
            end
            conflicts << rows if rows.map { |row| row[:vni] }.uniq.size > 1
            conflicts.each do |evidence|
              finding(fabric, nil, "fabric_subnet_vni_conflict", "VRF #{vrf} 的网段在不同 VNI 上重叠，需核对迁移或隔离设计", evidence)
            end
            active << [ key, rows ]
          end
        end
      end

      # 属性比较保留各叶节点值；显式缺失与 nil 不静默套用设备默认值。
      def compare(fabric, vni, code, title, rows, &value)
        evidence = observations(rows, &value)
        finding(fabric, vni, code, title, evidence) if evidence.map { |row| row[:value] }.uniq.size > 1
      end

      # 观察附带设备名、地址及本地 VLAN，报告可直接定位配置入口。
      def observations(rows)
        rows.map { |row| { host: row[:host], name: @documents[row[:host]]["device"]["name"], vlan: row[:vlan], value: yield(row) } }
      end

      # 按业务问题计数，不把证据行数当作问题数量。
      def finding(fabric, vni, code, title, evidence)
        @findings << { fabric: fabric, role: @role, vni: vni, code: code, title: title, evidence: evidence }
      end

      # 与单设备报告共享建议字段，跨设备来源完整保留。
      def recommendation(fabric, vni, code, title, evidence)
        { code: code, category: "fabric", scope: "#{fabric} / #{@role} / #{vni ? "VNI #{vni}" : '角色核查'}", title: title, status: "blocked", evidence: evidence,
          prerequisites: [ "仅在本 Fabric、相同已部署业务范围内适用；核对业务访问策略与维护窗口。", "下发前重新读取配置，任何变化均使计划过期；逐设备逐项确认，不批量重放。" ], blockers: [],
          commands: [], rollback: [], verify: [ "show running-config", "show nve vni", "show ip interface brief vrf all" ],
          impact: "改变网关或 ACL 可能改变可达性及业务隔离；配置回读通过后仍需业务验收。", expected: "共同业务的网关和访问控制一致，允许/拒绝流量均符合设计。", references: [] }
      end

      # 类型化增量才可导出可交互执行的计划，冲突项只有证据和待确认信息。
      def propose(item, plan, service_blocked:)
        if service_blocked
          item[:blockers] << "共同业务的承载关联或复制/路由声明存在冲突，先解决这些前置问题，再生成网关或 ACL 增量。"
          return
        end
        item.merge!(status: "candidate", change: plan.to_h, commands: plan.commands, rollback: plan.rollback)
      end
    end
  end
end
