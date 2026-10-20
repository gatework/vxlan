# frozen_string_literal: true

module Vxlan
  class ChangePlan
    # 只把既有未关联 VLAN 接入已经部署且业务一致的 L2 VNI。
    class VlanVni < ChangePlan
      KIND = "vlan_vni_add"
      FIELDS = [ *ChangePlan::FIELDS, "vrf", "address" ].freeze

      private

      def validate_parameters!
        super
        validate_gateway!
      end

      def render
        [ [ "configure terminal", "vlan #{@change['vlan']}", "  vn-segment #{@change['vni']}", "end" ],
          [ "configure terminal", "vlan #{@change['vlan']}", "  no vn-segment", "end" ] ]
      end

      def eligible_state?(config)
        mappings = config.fetch("vlan_vnis", {})
        mappings.key?(@change["vlan"].to_s) && mappings[@change["vlan"].to_s].nil? && target_state?(config)
      end

      # 补关联前后均须保留唯一 VNI、业务网关及完整的 NVE/EVPN L2 承载。
      def target_state?(config)
        member = config.dig("nve", "members", @change["vni"].to_s)
        gateway_context?(config) && config.dig("interfaces", interface, "addresses") == [ @change["address"] ] &&
          member && member["associate_vrf"] == false && config.dig("evpn", @change["vni"].to_s, "type") == "l2" &&
          config.fetch("vlan_vnis", {}).none? { |vlan, vni| vlan != @change["vlan"].to_s && vni == @change["vni"] }
      end

      def remove_changed_fields(context)
        context.fetch("vlan_vnis", {}).delete(@change["vlan"].to_s)
      end
    end
  end
end
