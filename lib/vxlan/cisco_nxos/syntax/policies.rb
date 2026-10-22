# frozen_string_literal: true

module Vxlan
  module CiscoNxos
    module Syntax
      # 前缀列表与路由映射保留地址族及引用选择器。
      module Policies
        private

        # 地址组是 ACL 语义的一部分；未知成员不能当成空组或完整配置。
        def address_group(block)
          sequences, members = {}, []
          analyze_children(block) do |child|
            match = /\A(\d+) (host )?(\S+)\z/.match(child.text)
            next issue(child) unless match
            sequence = integer(match[1], 1..4_294_967_295)
            raise ArgumentError if sequences.key?(sequence)
            sequences[sequence] = true
            value = match[3]
            value = "#{ip_address(value)}/32" if match[2]
            members << network_prefix(value, family: "ipv4")
          end
          members.uniq.sort
        end

        # 解析有序 IP 前缀列表条目及匹配边界。
        def prefix_list(block, lists, family:)
          return ignore(block) if /\A(?:ip|ipv6) prefix-list \S+ description .+\z/.match?(block.text)
          match = /\A(?:ip|ipv6) prefix-list (\S+) seq (\d+) (permit|deny) (\S+)(?: ge (\d+))?(?: le (\d+))?\z/.match(block.text)
          raise ArgumentError unless match
          sequence = integer(match[2], 1..4_294_967_295)
          collection = family == "ipv6" ? :ipv6_prefix_lists : :prefix_lists
          entries = (lists[match[1]] ||= [])
          policy_entry(collection, match[1], sequence, entries, block) do
            subnet = network_prefix(match[4], family: family)
            length, width = IPAddr.new(subnet).prefix, family == "ipv6" ? 128 : 32
            ge, le = match[5]&.to_i, match[6]&.to_i
            raise ArgumentError if (ge && !(length..width).cover?(ge)) || (le && !((ge || length)..width).cover?(le))

            { sequence: sequence, action: match[3], prefix: subnet, ge: ge, le: le }
          end
        end

        # 用固定槽位排除冲突序号，避免反复扫描或移动整个策略数组。
        def policy_entry(collection, name, sequence, entries, block)
          key = [ collection, name, sequence ]
          if (previous = @policy_sequences[key])
            entries[previous.fetch(:index)] = nil
            @cursor.mark(previous.fetch(:block).index, state: :invalid)
            code = collection == :route_maps ? :duplicate_route_map_entry : :invalid_configuration_value
            return issue(block, code)
          end
          @policy_sequences[key] = { index: entries.size, block: block }
          entries << nil
          entry = yield
          entries[-1] = entry
          @policy_sources[entry] = block
          entry
        end

        # 冲突处理完毕后按最终索引捕获来源，路径与公开结果保持一致。
        def finalize_policies(data)
          %i[prefix_lists ipv6_prefix_lists route_maps].each do |collection|
            data.fetch(collection).each do |name, entries|
              entries.compact!
              entries.each_with_index do |entry, index|
                capture(@policy_sources.fetch(entry), entry, [ collection, name, index ])
              end
            end
          end
        end

        # 解析有序 route-map 条目及策略引用。
        def route_map(block)
          values = { prefix_lists: [], additional_matches: [], sets: [] }
          analyze_children(block) do |child|
            case child.text
            when /\Amatch (ip|ipv6) (address|next-hop|route-source) prefix-list (.+)\z/
              family, selector, names = $1 == "ip" ? "ipv4" : "ipv6", $2, $3.split(" ")
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
