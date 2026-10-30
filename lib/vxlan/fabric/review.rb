# frozen_string_literal: true

require "ctx_runner/evidence"
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
        @documents = documents.to_h { |document| [ document.fetch("target").fetch("host"), document ] }
        raise ArgumentError, "Duplicate device identity" unless @documents.size == documents.size
        @scope = Scope.new(policy)
      end

      # 缺少任何成员的完整配置时仍报告覆盖，但不据此生成跨设备增量。
      def call
        @findings, @items, @coverage, @subnet_indexes = [], Hash.new { |hash, host| hash[host] = [] }, [], {}
        inventory = @scope.coverage(@documents.keys)
        finding("unassigned", nil, "fabric_scope_unassigned", "Collected devices are outside the Fabric policy and are not covered by cross-device review", inventory[:unassigned]) if inventory[:unassigned].any?
        @scope.groups.each do |fabric, group|
          configs = group.values.flatten.to_h { |host| [ host, configuration(host) ] }
          unknown = configs.select { |_host, config| config.nil? }.keys
          unless unknown.empty?
            finding(fabric, nil, "fabric_evidence_incomplete", "Member configuration evidence is incomplete; change inference stopped for this Fabric", unknown)
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
        { schema_version: CtxRunner::Evidence::VERSION, kind: "fabric_review", scope: "same_role_same_deployed_vni", inventory: inventory, findings: @findings, device_items: @items.to_h, coverage: @coverage }
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
            finding(fabric, vni, "fabric_service_incomplete", "Service deployment has started, but VLAN/NVE/EVPN associations are incomplete", observations(incomplete) { |row| { missing: row[:missing] } })
            review_missing_mappings(fabric, vni, rows, all_configs)
          end
          if rows.map { |row| row[:host] }.uniq.size != rows.size
            finding(fabric, vni, "fabric_vlan_mapping_ambiguous", "One Leaf maps multiple VLANs to the same VNI", rows.map { |row| row.slice(:host, :vlan) })
            next
          end
          next unless rows.size >= 2
          constraints = review_transport(fabric, vni, rows)
          service_blocked = incomplete.any? || constraints
          # 缺映射行没有可定位 SVI，不能再扩散为网关、MTU 等一串伪差异。
          rows = rows.select { |row| row[:vlan] }
          next unless rows.size >= 2
          compare(fabric, vni, "fabric_vlan_mapping", "Local VLAN IDs differ for the same VNI", rows) { |row| row[:vlan] }
          # L2 业务没有网关可以是正常设计，但仍须检查承载与控制平面。
          next unless rows.any? { |row| row[:svi] && (row[:svi]["anycast"] || row[:svi].fetch("addresses", []).any?) }
          review_gateway(fabric, vni, rows, all_configs, service_blocked: service_blocked)
          %w[in out].each { |direction| review_acl(fabric, vni, rows, direction, policies: policies, service_blocked: service_blocked) }
          %w[vrf anycast mtu shutdown].each do |field|
            compare(fabric, vni, "fabric_#{field}", "Service SVI #{field} differs", rows) { |row| row[:svi]&.fetch(field, nil) }
          end
          compare(fabric, vni, "fabric_anycast_mac", "Anycast gateway MACs differ", rows) { |row| row[:config]["anycast_mac"] }
        end
        review_acl_catalog(fabric, configs, policies)
        review_address_groups(fabric, configs)
      end

      # 已有 NVE/EVPN 的缺映射业务单独推导，不把不完整关联当作从未部署。
      def review_missing_mappings(fabric, vni, rows, configs)
        rows.select { |row| row[:missing] == [ "VLAN" ] }.each do |row|
          evidence = observations(rows) { |peer| { missing: peer[:missing], gateway: peer[:svi]&.fetch("addresses", []), vrf: peer[:svi]&.dig("vrf") } }
          item = recommendation(fabric, vni, "fabric_vlan_mapping_missing", "Complete the VLAN/VNI association for an existing service", evidence)
          plan = Service::Mapping.infer(vni, row, rows)
          change = plan&.to_h
          conflicts = change ? gateway_conflicts(configs, change, except: [ row[:host], "Vlan#{change['vlan']}" ]) : []
          if conflicts.any?
            item[:evidence].concat(conflicts)
            item[:blockers] << "Subnets overlap across SVIs/VNIs within the same VRF; adding a mapping must not extend the conflict: #{conflicts.map { |entry| "#{entry[:name]} #{entry[:interface]}" }.join(', ')}"
            plan = nil
          end
          if plan
            local_svi = row[:config].fetch("interfaces").fetch("Vlan#{change['vlan']}")
            item[:evidence] = evidence.map do |entry|
              entry[:host] == row[:host] ? entry.merge(vlan: change["vlan"].to_s, value: { missing: [ "VLAN/VNI mapping" ], gateway: local_svi["addresses"], vrf: local_svi["vrf"] }) : entry
            end
            item[:impact] = "Attaching an existing VLAN to an existing VXLAN service may immediately extend the broadcast domain; no VLAN is created and gateways and ACLs are unchanged."
            item[:prerequisites] << "The unmapped local VLAN's gateway, VRF, Anycast identity and ACL match a complete peer, and NVE/EVPN already match; confirm that this service should be attached locally."
            item[:expected] = "Local VLAN/VNI association is complete, VNI state meets expectations, existing gateway and ACL remain unchanged, and service acceptance passes."
            item[:resolves] = [ { code: "nve_l2_without_vlan", vni: vni } ]
            propose(item, plan, service_blocked: false)
          else
            item[:blockers] << "No unique and complete service correspondence exists; compare the local unmapped VLAN, gateway, VRF and ACL with peer configuration. Do not infer VLAN from VNI numbers."
          end
          @items[row[:host]] << item
        end
      end

      # 一致性约束先于增量生成；承载/路由声明冲突时停止叠加网关和 ACL 变更。
      def review_transport(fabric, vni, rows)
        before = @findings.size
        compare(fabric, vni, "fabric_replication", "NVE replication modes or multicast group declarations differ", rows) { |row| Service::Catalog.nve_member(row[:config], row[:nve])&.slice("replication", "multicast_group") }
        compare(fabric, vni, "fabric_arp_suppression", "Explicit ARP suppression settings differ", rows) { |row| row[:nve]&.fetch("suppress_arp", nil) }
        compare(fabric, vni, "fabric_route_targets", "EVPN import/export RT declarations differ; verify routing reachability and isolation", rows) do |row|
          row[:evpn] && Service::Catalog.route_targets(row[:evpn]["route_targets"], asn: row[:config].dig("bgp", "asn"), vni: vni)
        end
        tenant_rows = rows.select { |row| row[:svi] && row[:svi]["vrf"] }
        compare(fabric, vni, "fabric_tenant_routing", "Tenant VNIs or route import/export declarations differ for a shared service", tenant_rows) do |row|
          Service::Catalog.tenant(row[:config], row[:svi]["vrf"])
        end if tenant_rows.size >= 2
        @findings.size > before
      end

      # Spine 角色的业务承载配置保留为待决项，不能自动补齐或删除疑似残留。
      def review_spine(fabric, host, config)
        services = Service::Catalog.new(host => config).services
        return if services.empty?
        evidence = [ { host: host, value: { role: "spines", l2_vnis: services.keys.sort } } ]
        finding(fabric, nil, "fabric_role_conflict", "Declared as Spine but contains L2 service-bearing configuration", evidence)
        item = recommendation(fabric, nil, "fabric_role_conflict", "Verify whether the Spine should act as a service VTEP", evidence)
        item[:blockers] << "Confirm the role or migration remnants first; NVE presence does not automatically make a Spine a Leaf. Do not automatically add service configuration or delete NVE."
        @items[host] << item
      end

      # 网关不一致与地址迁移分开；未知目标不做替换，仅允许无冲突的缺失地址补齐。
      def review_gateway(fabric, vni, rows, configs, service_blocked:)
        values = rows.map { |row| row[:svi]&.fetch("addresses", [])&.sort }
        return if values.uniq.one?
        finding(fabric, vni, "fabric_gateway", "Gateway addresses differ for the same service", observations(rows) { |row| row[:svi]&.fetch("addresses", []) })
        expected = values.compact.reject(&:empty?).uniq
        rows.each do |row|
          next if expected.one? && row[:svi]&.fetch("addresses", [])&.sort == expected.first
          item = recommendation(fabric, vni, "fabric_gateway", "Gateway addresses must be consistent", observations(rows) { |entry| entry[:svi]&.fetch("addresses", []) })
          change = { "kind" => "svi_gateway_add", "vlan" => row[:vlan].to_i, "vni" => vni, "vrf" => row[:svi]&.dig("vrf"), "address" => expected.one? && expected.first.one? ? expected.first.first : nil }
          context = rows.map { |entry| [ entry[:svi]&.dig("vrf"), entry[:svi]&.dig("anycast"), entry[:config]["anycast_mac"] ] }.uniq
          conflicts = change["address"] ? gateway_conflicts(configs, change) : []
          item[:evidence].concat(conflicts)
          if conflicts.empty? && context.one? && context.first.all? && expected.one? && expected.first.one? &&
              (plan = ChangePlan.candidate(change, config: row[:config]))
            propose(item, plan, service_blocked: service_blocked)
          else
            item[:blockers] << "An existing address, cross-SVI/VNI subnet conflict, inconsistent VRF/Anycast mode/MAC, or lack of a unique gateway prevents this change; confirm the migration design first. Do not add duplicate gateways."
            item[:blockers] << "Conflicting interfaces in the Fabric: #{conflicts.map { |conflict| "#{conflict[:name]} #{conflict[:interface]}" }.join(', ')}" if conflicts.any?
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
            { host: host, name: @documents[host]["target"]["name"], **entry }
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
        finding(fabric, vni, code, "#{direction} ACL attachments or ordered rules differ", evidence)
        undefined = evidence.select { |row| row[:value][:acl] && !row[:value][:defined] }
        finding(fabric, vni, "fabric_acl_undefined", "#{direction} ACL is attached but its local definition is missing", undefined) if undefined.any?
        unresolved = evidence.select { |row| row[:value][:defined] && !row[:value][:policy_verified] }
        finding(fabric, vni, "fabric_acl_dependency", "#{direction} ACL dependencies are missing, empty or unparsed; policy consistency cannot be established", unresolved) if unresolved.any?
        names = bindings.compact.uniq
        sources = rows.select { |row| row[:config].fetch("acls", {})[names.first] }
        originals = sources.map { |row| row[:config]["acls"][names.first] }
        unique = sources.map { |row| policies.dig(row[:host], names.first) }.uniq
        rows.each do |row|
          current_name = row[:svi]&.dig("acl_bindings", direction)
          current_entries = names.one? && row[:config].fetch("acls", {})[names.first]
          next if names.one? && unique.one? && unique.first && current_name == names.first && policies.dig(row[:host], names.first) == unique.first
          item = recommendation(fabric, vni, code, "Align #{direction} access control", evidence)
          change = { "kind" => "svi_acl", "vlan" => row[:vlan].to_i, "vni" => vni, "direction" => direction,
            "acl" => names.first, "entries" => originals.first, "create_acl" => current_entries.nil?, "previous_binding" => current_name }
          change["address_groups"] = unique.first.address_groups if unique.one? && unique.first
          context_matches = rows.map { |entry| entry[:svi]&.dig("vrf") }.uniq.one?
          if names.one? && unique.one? && unique.first && context_matches &&
              (plan = ChangePlan.candidate(change, config: row[:config]))
            item[:prerequisites] << "The basis is an ACL attached to this service with matching ordered contents; even if fewer nodes attach it, a majority without an ACL is not grounds for removal. Confirm that the service should uniformly use this ACL."
            propose(item, plan, service_blocked: service_blocked)
          else
            item[:blockers] << "ACL names, ordered rules, address group members, VRF or current bindings do not establish consistency; choose authoritative rules and complete dependencies. Do not automatically overwrite or remove access control."
            shared = change["create_acl"] ? AclPolicy.bindings(row[:config], names.first) - [ { "interface" => "Vlan#{row[:vlan]}", "direction" => direction } ] : []
            if shared.any?
              references = shared.map { |binding| "#{binding['interface']} #{binding['direction']}" }.join(", ")
              item[:blockers] << "Creating #{names.first} would also activate existing references: #{references}. Review policy and rollback for all affected interfaces together; do not execute this as completion of a single SVI."
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
            finding(fabric, nil, "fabric_acl_content", "Same-name ACL #{name} has different ordered rules or dependencies (including unattached definitions)", rows)
          end
          unknown = rows.select { |row| row[:policy].nil? }
          finding(fabric, nil, "fabric_acl_dependency", "ACL #{name} has unverified dependencies; policy consistency cannot be established (including unattached definitions)", unknown) if unknown.any?
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
          finding(fabric, nil, "fabric_address_group", "ACL address group #{name} has different or missing members; compare only services referencing this object and do not copy automatically", rows)
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
              finding(fabric, nil, "fabric_subnet_vni_conflict", "VRF #{vrf} has overlapping subnets across different VNIs; verify the migration or isolation design", evidence)
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
        rows.map { |row| { host: row[:host], name: @documents[row[:host]]["target"]["name"], vlan: row[:vlan], value: yield(row) } }
      end

      # 按业务问题计数，不把证据行数当作问题数量。
      def finding(fabric, vni, code, title, evidence)
        @findings << { fabric: fabric, role: @role, vni: vni, code: code, title: title, evidence: evidence }
      end

      # 与单设备报告共享建议字段，跨设备来源完整保留。
      def recommendation(fabric, vni, code, title, evidence)
        { code: code, category: "fabric", scope: "#{fabric} / #{@role} / #{vni ? "VNI #{vni}" : 'role review'}", title: title, status: "blocked", evidence: evidence,
          prerequisites: [ "Applicable only within this Fabric and the same deployed service scope; verify the service access policy and maintenance window.", "Read configuration again before applying; any change makes the plan stale. Confirm each item on each device; do not replay in bulk." ], blockers: [],
          commands: [], rollback: [], verify: [ "show running-config", "show nve vni", "show ip interface brief vrf all" ],
          impact: "Changing a gateway or ACL may affect reachability and service isolation; service acceptance is still required after configuration readback passes.", expected: "Gateways and access control are consistent for the shared service; permitted and denied traffic match the design.", references: [] }
      end

      # 类型化增量才可导出可交互执行的计划，冲突项只有证据和待确认信息。
      def propose(item, plan, service_blocked:)
        if service_blocked
          item[:blockers] << "Service-bearing associations or replication/routing declarations conflict for a shared service; resolve these prerequisites before generating gateway or ACL changes."
          return
        end
        item.merge!(status: "candidate", change: plan.to_h, commands: plan.commands, rollback: plan.rollback)
      end
    end
  end
end
