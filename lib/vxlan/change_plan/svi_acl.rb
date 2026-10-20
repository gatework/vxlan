# frozen_string_literal: true

module Vxlan
  class ChangePlan
    # 补齐单个 SVI 的 ACL 保护，固定有序规则与依赖，不覆盖其他策略。
    class SviAcl < ChangePlan
      KIND = "svi_acl"
      FIELDS = [ *ChangePlan::FIELDS, *%w[acl direction entries address_groups create_acl previous_binding] ].freeze

      private

      def validate_parameters!
        super
        name, direction = @change.values_at("acl", "direction")
        raise ArgumentError, "ACL 参数无效" unless name.is_a?(String) && name.match?(/\A[A-Za-z0-9_.-]{1,63}\z/) && %w[in out].include?(direction)
        raise ArgumentError, "ACL 创建状态无效" unless [ true, false ].include?(@change["create_acl"])
        raise ArgumentError, "不能覆盖既有绑定" unless [ nil, name ].include?(@change["previous_binding"])
        groups = @change.fetch("address_groups", {})
        raise ArgumentError, "ACL 依赖未验证" unless groups.is_a?(Hash)
        @policy = AclPolicy.resolve({ "address_groups" => groups }, @change["entries"])
        raise ArgumentError, "ACL 规则或依赖未验证" unless @policy && @policy.address_groups == groups
        raise ArgumentError, "无有效 ACL 规则" if @policy.rules.empty?
        @rule_commands = rule_commands
      end

      # 策略已证明序号和结构有效；这里只约束可下发的命令语法，备注不下发。
      def rule_commands
        rules = @change["entries"].sort_by { |entry| entry["sequence"] }.filter_map do |entry|
          next if entry["action"] == "remark"
          action, expression = entry.values_at("action", "expression")
          unless %w[permit deny].include?(action) && expression.is_a?(String) && expression.match?(/\A(?:ip|tcp|udp|icmp|igmp|gre|esp|ah|ospf) [A-Za-z0-9_.:\/ -]+\z/)
            raise ArgumentError, "ACL 规则语法未验证"
          end
          "  #{entry['sequence']} #{action} #{expression}"
        end
        CtxParser::Immutable.copy(rules)
      end

      def render
        name, direction = @change.values_at("acl", "direction")
        additions = @change["create_acl"] ? [ "ip access-list #{name}", *@rule_commands, "exit" ] : []
        commands = [ "configure terminal", *additions, "interface #{interface}", "  ip access-group #{name} #{direction}", "end" ]
        rollback = [ "configure terminal" ]
        rollback.concat([ "interface #{interface}", "  no ip access-group #{name} #{direction}", "exit" ]) unless @change["previous_binding"]
        rollback << "no ip access-list #{name}" if @change["create_acl"]
        [ commands, [ *rollback, "end" ] ]
      end

      def eligible_state?(config)
        svi = mapped_svi(config)
        return false unless svi && AclPolicy.resolve(config, @change["entries"]) == @policy
        return false if @change["create_acl"] && !creation_isolated?(config)
        entries = config.fetch("acls", {})[@change["acl"]]
        svi.fetch("acl_bindings", {})[@change["direction"]] == @change["previous_binding"] &&
          (@change["create_acl"] ? entries.nil? : AclPolicy.rules(entries) == @policy.rules)
      end

      def target_state?(config)
        return false if @change["create_acl"] && !creation_isolated?(config)
        config.dig("interfaces", interface, "acl_bindings", @change["direction"]) == @change["acl"] &&
          AclPolicy.resolve(config, config.fetch("acls", {})[@change["acl"]]) == @policy
      end

      # 新建定义不能顺带激活其他接口或方向的既有引用。
      def creation_isolated?(config)
        target = { "interface" => interface, "direction" => @change["direction"] }
        (AclPolicy.bindings(config, @change["acl"]) - [ target ]).empty?
      end

      def remove_changed_fields(context)
        context.dig("interfaces", interface, "acl_bindings")&.delete(@change["direction"])
        context.fetch("acls", {}).delete(@change["acl"]) if @change["create_acl"]
      end
    end
  end
end
