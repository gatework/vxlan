# frozen_string_literal: true

module Vxlan
  class ChangePlan
    # 仅为空 SVI 补齐同业务网关，不替换已有地址或租户身份。
    class SviGateway < ChangePlan
      KIND = "svi_gateway_add"
      FIELDS = [ *ChangePlan::FIELDS, "vrf", "address" ].freeze

      private

      def validate_parameters!
        super
        validate_gateway!
      end

      def render
        [ [ "configure terminal", "interface #{interface}", "  ip address #{@change['address']}", "end" ],
          [ "configure terminal", "interface #{interface}", "  no ip address #{@change['address']}", "end" ] ]
      end

      def eligible_state?(config)
        svi = mapped_svi(config)
        svi && gateway_context?(config) && svi.fetch("addresses", []).empty?
      end

      def target_state?(config)
        gateway_context?(config) && config.dig("interfaces", interface, "addresses") == [ @change["address"] ]
      end

      def remove_changed_fields(context)
        context.dig("interfaces", interface)&.delete("addresses")
      end
    end
  end
end
