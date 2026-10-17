# frozen_string_literal: true

module Vxlan
  module CiscoNxos
    module Syntax
      # 前缀列表与路由映射保留地址族及引用选择器。
      module Policies
        private

        # 解析有序 IP 前缀列表条目及匹配边界。
        def prefix_list(block, lists, family:)
          return ignore(block) if /\A(?:ip|ipv6) prefix-list \S+ description .+\z/.match?(block.text)
          match = /\A(?:ip|ipv6) prefix-list (\S+) seq (\d+) (permit|deny) (\S+)(?: ge (\d+))?(?: le (\d+))?\z/.match(block.text)
          raise ArgumentError unless match
          subnet = network_prefix(match[4], family: family)
          length, width = IPAddr.new(subnet).prefix, family == "ipv6" ? 128 : 32
          ge, le = match[5]&.to_i, match[6]&.to_i
          raise ArgumentError if (ge && !(length..width).cover?(ge)) || (le && !((ge || length)..width).cover?(le))
          entries = (lists[match[1]] ||= [])
          sequence = integer(match[2], 1..4_294_967_295)
          collection = family == "ipv6" ? :ipv6_prefix_lists : :prefix_lists
          raise ArgumentError if register_policy_sequence(collection, match[1], sequence)
          entries << { sequence: sequence, action: match[3], prefix: subnet, ge: ge, le: le }
          capture(block, entries.last, [ collection, match[1], entries.size - 1 ])
        end

        # 单次解析用索引识别重复序号，避免长策略逐条扫描已有条目。
        def register_policy_sequence(collection, name, sequence)
          key = [ collection, name, sequence ]
          duplicate = @policy_sequences.key?(key)
          @policy_sequences[key] = true
          duplicate
        end

        # 解析有序 route-map 条目及策略引用。
        def route_map(block)
          values = { prefix_lists: [], additional_matches: [], sets: [] }
          analyze_children(block) do |child|
            case child.text
            when /\Amatch (ip|ipv6) (address|next-hop|route-source) prefix-list (.+)\z/
              family, selector, names = $1 == "ip" ? "ipv4" : "ipv6", $2, $3.split
              values[:prefix_lists].concat(names) if family == "ipv4" && selector == "address"
              (values[:prefix_list_matches] ||= []) << { address_family: family, selector: selector, names: names }
            when /\Amatch / then values[:additional_matches] << child.text
            when /\Aset / then values[:sets] << child.text
            when /\Adescription / then ignore(child)
            else issue(child)
            end
          end
          values
        end

        # 归一化已配置的网络前缀及所属地址族。
        def network_prefix(value, family: nil)
          unless value.is_a?(String) && /\A[0-9a-f:.]+\/\d+\z/i.match?(value)
            raise ArgumentError, "A network prefix is required"
          end
          network = IPAddr.new(value)
          raise ArgumentError if family == "ipv4" && !network.ipv4? || family == "ipv6" && !network.ipv6?

          "#{network}/#{network.prefix}"
        end
      end
    end
  end
end
