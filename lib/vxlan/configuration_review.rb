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

      members = @configuration.fetch(:nve).fetch(:members, {})
      vlans = @configuration.fetch(:vlan_vnis).group_by { |_vlan, vni| vni }
      evpn = @configuration.fetch(:evpn)
      findings = []
      vlans.each do |vni, entries|
        next unless vni && !members.key?(vni)

        findings << { code: :vlan_vni_without_nve, vni: vni, vlan_ids: entries.map(&:first).sort }
      end
      members.each do |vni, settings|
        next if settings[:associate_vrf]

        findings << { code: :nve_l2_without_vlan, vni: vni } unless vlans.key?(vni)
        if @configuration[:nv_overlay_evpn] && !evpn.key?(vni)
          findings << { code: :nve_l2_without_evpn, vni: vni }
        end
      end
      evpn.each_key { |vni| findings << { code: :evpn_vni_without_nve, vni: vni } unless members.key?(vni) }
      @configuration.fetch(:vrfs).each do |name, settings|
        next unless settings[:vni]
        member = members[settings[:vni]]
        code = member ? (!member[:associate_vrf] ? :vni_layer_conflict : nil) : :l3_vni_without_nve
        findings << { code: code, vni: settings[:vni], vrf: name } if code
      end
      findings.sort_by { |finding| [ finding[:vni], finding[:code].to_s ] }
    end
  end
end
