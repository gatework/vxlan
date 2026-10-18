# frozen_string_literal: true

module Vxlan
  # 配置关联审查独立于语法解析及运行健康检查。
  class ConfigurationReview
    # 绑定归一化配置，用于交叉引用一致性检查。
    def initialize(configuration)
      @configuration = configuration
    end

    # 检查完整配置中的关联缺失或引用矛盾。
    def call(complete: false)
      raise ArgumentError, "Completeness must be boolean" unless [ true, false ].include?(complete)
      return [] unless complete

      nve_members_by_vni = @configuration.fetch(:nve).fetch(:members, {})
      vlan_mappings_by_vni = @configuration.fetch(:vlan_vnis).group_by { |_vlan, vni| vni }
      vrf_vnis = @configuration.fetch(:vrfs).values.filter_map { |settings| settings[:vni] }.to_set
      evpn_vnis = @configuration.fetch(:evpn)
      findings = []
      vlan_mappings_by_vni.each do |vni, entries|
        next unless vni && !nve_members_by_vni.key?(vni)

        findings << { code: :vlan_vni_without_nve, vni: vni, vlan_ids: entries.map(&:first).sort }
      end
      nve_members_by_vni.each do |vni, settings|
        if settings[:associate_vrf]
          findings << { code: :nve_l3_without_vrf, vni: vni } unless vrf_vnis.include?(vni)
          next
        end

        findings << { code: :nve_l2_without_vlan, vni: vni } unless vlan_mappings_by_vni.key?(vni)
        if @configuration[:nv_overlay_evpn] && !evpn_vnis.key?(vni)
          findings << { code: :nve_l2_without_evpn, vni: vni }
        end
      end
      evpn_vnis.each do |vni, settings|
        member = nve_members_by_vni[vni]
        if !member
          findings << { code: :evpn_vni_without_nve, vni: vni }
        elsif (settings[:type] == "l3") != member[:associate_vrf]
          findings << { code: :vni_layer_conflict, vni: vni, evpn_type: settings[:type] }
        end
      end
      @configuration.fetch(:vrfs).each do |name, settings|
        next unless settings[:vni]
        member = nve_members_by_vni[settings[:vni]]
        code = member ? (!member[:associate_vrf] ? :vni_layer_conflict : nil) : :l3_vni_without_nve
        findings << { code: code, vni: settings[:vni], vrf: name } if code
      end
      findings.sort_by { |finding| [ finding[:vni], finding[:code].to_s ] }
    end
  end
end
