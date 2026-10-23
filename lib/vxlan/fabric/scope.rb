# frozen_string_literal: true

require "ipaddr"
require "ctx_parser/immutable"

module Vxlan
  module Fabric
    # Fabric 与角色是业务边界，名称和地址相似不能替代显式成员声明。
    class Scope
      ROLES = %w[leaves borders spines].freeze
      attr_reader :groups

      # 在入口验证唯一归属；允许单角色为空，但 Fabric 至少有两个成员。
      def initialize(policy)
        unless policy.is_a?(Hash) && policy.keys == [ "fabrics" ] && policy["fabrics"].is_a?(Hash) && policy["fabrics"].any?
          raise ArgumentError, "A fabrics policy is required"
        end
        @groups = policy["fabrics"].to_h do |name, group|
          unless name.is_a?(String) && !name.empty? && group.is_a?(Hash) && (group.keys - ROLES).empty? && group.any?
            raise ArgumentError, "Fabric requires explicit role member lists"
          end
          roles = ROLES.to_h do |role|
            hosts = group.fetch(role, [])
            raise ArgumentError, "Role members must be address lists" unless hosts.is_a?(Array)
            hosts.each { |host| raise ArgumentError, "Invalid member address" unless host.is_a?(String) && !host.include?("/") && IPAddr.new(host).to_s == host }
            [ role, CtxParser::Immutable.copy(hosts) ]
          end
          raise ArgumentError, "Fabric requires at least two members" unless roles.values.flatten.size >= 2
          [ name, roles.freeze ]
        end.freeze
        raise ArgumentError, "Members cannot be duplicated or shared across roles or Fabrics" unless hosts.uniq == hosts
      end

      # 扁平成员集合用于覆盖核对，不改变角色内的比较范围。
      def hosts = groups.values.flat_map { |roles| roles.values.flatten }

      # 未采集与未纳入是两种不同缺口，均不能被无发现掩盖。
      def coverage(observed_hosts)
        { groups: groups, assigned: hosts & observed_hosts, unassigned: observed_hosts - hosts, missing: hosts - observed_hosts }
      end
    end
  end
end
