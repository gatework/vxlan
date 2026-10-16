# frozen_string_literal: true

require "digest"
require "ipaddr"
require_relative "../configuration_parsing/interfaces"
require_relative "../configuration_parsing/routing"
require_relative "../configuration_parsing/policies"
require_relative "../configuration_document"
require_relative "../configuration"
require_relative "../../configuration_review"
require "ctx_parser/configuration_parser"
require "ctx_parser/values"

module Vxlan
  module CiscoNxos
    module Parsers
      # 按 NX-OS 缩进确定作用域；相关语法不受支持时保留部分结果。
      class ShowRunningConfig < CtxParser::ConfigurationParser
        include ConfigurationParsing::Interfaces
        include ConfigurationParsing::Routing
        include ConfigurationParsing::Policies

        private

        # 解析运行配置，不依赖传输或资产清单。
        def parse_output(text, complete:)
          configuration = CiscoNxos::Configuration.new
          @issues = configuration.issues
          @conflicts = {}
          @sources = {}
          @feature_sources = []
          @disabled_feature_sources = []
          data = configuration.data
          read_configuration(text, comments: /\A!/, boundaries: /\Aend\z/, document_class: ConfigurationDocument).each { |block| parse_block(block, data) }
          @issues.concat(document.issues)
          # 所有声明读取完毕后再关联模板与网段，避免配置先后顺序改变关联结果。
          configuration.finish
          @feature_sources.each { |block, feature| capture(block, feature, [ :features, data[:features].index(feature) ]) }
          @disabled_feature_sources.each { |block, feature| capture(block, feature, [ :disabled_features, data[:disabled_features].index(feature) ]) }
          data[:config_digest] = Digest::SHA256.hexdigest(@cursor.lines.map(&:raw).reject { |line| line.strip.empty? || line.lstrip.start_with?("!") }.map(&:rstrip).join("\n"))
          @issues << { code: :output_incomplete } unless complete
          status = @issues.empty? ? :complete : :partial
          data[:review_status] = status
          data[:review_findings] = Vxlan::ConfigurationReview.new(data).call(complete: status == :complete)
          CtxParser::Result.new(status: status, records: [ data ], issues: @issues)
        end

        # 分派单个配置块，同时保留来源作用域。
        def parse_block(block, data)
          analyze(block) { parse_setting(block, data) }
        rescue ArgumentError, IPAddr::Error
          issue(block, :invalid_configuration_value)
        end

        # 在所属父级配置作用域内解释一项支持的设置。
        def parse_setting(block, data)
          case block.text
          when /\Ahostname (\S+)\z/
            issue(block, :duplicate_hostname) if data[:hostname]
            data[:hostname] = $1
            capture(block, data[:hostname], [ :hostname ])
          when /\Afeature (.+)\z/
            data[:features] << $1
            @feature_sources << [ block, $1 ]
          when /\Ano feature (.+)\z/
            data[:disabled_features] << $1
            @disabled_feature_sources << [ block, $1 ]
          when /\Ainterface breakout module (\d+) port (\d+) map (\d+g-\d+x)\z/
            module_id, port, mapping = integer($1, 1..65_535), integer($2, 1..65_535), $3
            key = "#{module_id}/#{port}"
            store(data[:breakouts], key, block, path: [ :breakouts, key ]) { { module_id: module_id, port: port, map: mapping } }
          when /\Ainterface (\S+)\z/
            name = $1.sub(/\Avlan/i, "Vlan")
            if name.match?(/\Anve\d+\z/i)
              issue(block, :multiple_nve_interfaces) if data[:nve][:interface]
              data[:nve] = scope(block, [ :nve ]) { nve(block).merge(interface: name) }
            else
              store(data[:interfaces], name, block, path: [ :interfaces, name ]) { interface(block) }
            end
          when /\Avlan ([\d,-]+)\z/
            ids = $1.split(",", -1).flat_map do |part|
              raise ArgumentError unless /\A\d+(?:-\d+)?\z/.match?(part)
              first, last = part.split("-").map { |value| integer(value, 1..4094) }
              raise ArgumentError if last && last < first
              (first..(last || first)).to_a
            end
            # NX-OS 先输出 VLAN 汇总，再输出各 VLAN 的独立配置块。
            return if block.children.empty?

            mappings = block.children.select { |child| child.text.start_with?("vn-segment") }
            ids.uniq.each do |id|
              store(data[:vlan_vnis], id, block, path: [ :vlan_vnis, id ]) do
                raise ArgumentError if mappings.size > 1
                vni = mappings.first && analyze(mappings.first) { integer(mappings.first.text.delete_prefix("vn-segment "), 1..16_777_215) }
                raise ArgumentError if vni && ids.uniq.size != 1
                vni
              end
            end
            block.children.each { |child| ignore(child) unless mappings.include?(child) }
          when /\Avrf context (\S+)\z/ then store(data[:vrfs], $1, block, path: [ :vrfs, $1 ]) { vrf(block) }
          when "evpn"
            analyze_children(block) do |child|
              if (match = /\Avni (\d+) (l[23])\z/i.match(child.text))
                id = integer(match[1], 1..16_777_215)
                store(data[:evpn], id, child, path: [ :evpn, id ]) { vrf(child).merge(type: match[2].downcase) }
              else
                issue(child)
              end
            end
          when /\Avpc domain (\d+)\z/
            issue(block, :duplicate_vpc_domain) if data[:vpc_domain]
            id = integer($1, 1..1000)
            data[:vpc_domain] = scope(block, [ :vpc_domain ]) { vpc(block).merge(id: id) }
          when /\Arouter bgp (\d+)\z/
            asn = integer($1, 1..4_294_967_295)
            issue(block, :duplicate_bgp_process) if data[:bgp].any?
            data[:bgp] = scope(block, [ :bgp ]) { routing(block, :bgp).merge(asn: asn) }
          when /\Arouter ospf (\S+)\z/ then store(data[:ospf], $1, block, path: [ :ospf, $1 ]) { routing(block, :ospf) }
          when /\Aip prefix-list / then prefix_list(block, data[:prefix_lists], family: "ipv4")
          when /\Aipv6 prefix-list / then prefix_list(block, data[:ipv6_prefix_lists], family: "ipv6")
          when /\Aroute-map (\S+) (permit|deny) (\d+)\z/
            name, action, sequence = $1, $2, integer($3, 1..65_535)
            entries = (data[:route_maps][name] ||= [])
            issue(block, :duplicate_route_map_entry) if entries.any? { |entry| entry[:sequence] == sequence }
            entries << scope(block, [ :route_maps, name, entries.size ]) { route_map(block).merge(action: action, sequence: sequence) }
          when /\Aip access-list (\S+)\z/
            name = $1
            entries = block.children.filter_map do |child|
              analyze(child) do
                next ignore(child) if /\A(?:(?:\d+ )?remark\b|statistics per-entry\z)/.match?(child.text)
                match = /\A(\d+) (permit|deny) (.+)\z/.match(child.text)
                if match
                  { sequence: integer(match[1], 1..4_294_967_295), action: match[2], expression: match[3] }
                else
                  issue(child)
                  nil
                end
              end
            end
            store(data[:acls], name, block, path: [ :acls, name ]) { entries }
          when /\Aip route /
            data[:static_routes] << scope(block, [ :static_routes, data[:static_routes].size ]) { static_route(block) }
          when "nv overlay evpn", "no nv overlay evpn"
            data[:nv_overlay_evpn] = block.text == "nv overlay evpn"
            capture(block, data[:nv_overlay_evpn], [ :nv_overlay_evpn ])
          when /\Afabric forwarding anycast-gateway-mac (\S+)\z/
            data[:anycast_mac] = $1
            capture(block, data[:anycast_mac], [ :anycast_mac ])
          when /\A(?:interface|vlan|vrf|router|vpc|evpn|feature|ip prefix-list|ipv6 prefix-list|route-map)\b/ then issue(block)
          when /\A(?:%|ERROR:|Invalid command|--More--)/i then issue(block, :invalid_command_output)
          else
            check_unhandled(block)
          end
        end

        # 解析 VRF 定义及其 VNI 或 route-target 关联。
        def vrf(block)
          values = { route_targets: [], routes: [] }
          analyze_children(block) do |child|
            case child.text
            when /\Avni (\d+)\z/ then values[:vni] = integer($1, 1..16_777_215)
            when /\Ard (\S+)\z/ then values[:rd] = $1
            when /\Aroute-target / then values[:route_targets] << route_target(child)
            when /\Aaddress-family (.+)\z/
              family = $1
              targets_start = values[:route_targets].size
              exports_start = values.fetch(:exports, []).size
              analyze_children(child) do |setting|
                case setting.text
                when /\Aroute-target / then values[:route_targets] << route_target(setting).merge(address_family: family)
                when /\Aexport vrf default(?: (\d+))? map (\S+)( allow-vpn)?\z/
                  limit, route_map, allow_vpn = $1, $2, !$3.nil?
                  (values[:exports] ||= []) << { vrf: "default", prefix_limit: limit && integer(limit, 1..2_147_483_647),
                    route_map: route_map, allow_vpn: allow_vpn, address_family: family }
                else issue(setting)
                end
              end
              values[:route_targets].drop(targets_start).each_with_index do |target, index|
                capture(child, target, @source_path + [ :route_targets, targets_start + index ])
              end
              values.fetch(:exports, []).drop(exports_start).each_with_index do |export, index|
                capture(child, export, @source_path + [ :exports, exports_start + index ])
              end
            when /\Aip route /
              values[:routes] << scope(child, @source_path + [ :routes, values[:routes].size ]) { static_route(child) }
            when /\Adescription / then ignore(child)
            else issue(child)
            end
          end
          values
        end

        # 归一化 route-target 方向及地址族作用域。
        def route_target(block)
          match = /\Aroute-target (import|export|both) (\S+)( evpn)?\z/.match(block.text)
          raise ArgumentError unless match
          { direction: match[1], target: match[2], evpn: !match[3].nil? }
        end

        # 解析 vPC 域配置，不推断运行可用性。
        def vpc(block)
          values = { peer_keepalive: {}, virtual_peer_link: {}, peer_gateway: false, peer_switch: false, layer3_peer_router: false }
          analyze_children(block) do |child|
            case child.text
            when /\Apeer-keepalive (.+)\z/ then values[:peer_keepalive] = pairs($1, %w[destination source vrf])
            when /\Avirtual peer-link (.+)\z/ then values[:virtual_peer_link] = pairs($1, %w[destination source dscp])
            when "peer-gateway" then values[:peer_gateway] = true
            when "peer-switch" then values[:peer_switch] = true
            when "layer3 peer-router" then values[:layer3_peer_router] = true
            when "fast-convergence" then ignore(child)
            when /\A(?:role priority|system-priority|auto-recovery|delay restore|ip arp synchronize)\b/ then ignore(child)
            else issue(child)
            end
          end
          values
        end

        # 提取支持的键值配置对。
        def pairs(text, allowed)
          words = text.split
          raise ArgumentError unless words.size.even? && (words.each_slice(2).map(&:first) - allowed).empty?
          values = words.each_slice(2).to_h.transform_keys(&:to_sym)
          raise ArgumentError unless values.size == words.size / 2
          %i[source destination].each { |key| values[key] = address(values[key]) if values[key] }
          integer(values[:dscp], 0..63) if values[:dscp]
          values
        end

        # 归一化静态路由及可选下一跳属性。
        def static_route(block)
          words = block.text.split
          raise ArgumentError if words.size < 4
          { prefix: prefix(words[2]), next_hop: words[3], options: words.drop(4).join(" ") }
        end

        # 解析十进制整数，并校验声明的边界。
        def integer(value, range)
          raise ArgumentError unless value.is_a?(String)
          CtxParser::Values.integer(value, min: range.min, max: range.max)
        end

        # 校验接口地址，同时保留网络前缀。
        def address(value)
          CtxParser::Values.host(value, allow_zone: true)
        end

        # 校验网络前缀，不静默修正错误语法。
        def prefix(value, host: false) = CtxParser::Values.ipv4_prefix(value, host: host)

        # 保存已解析配置，同时保留其来源。
        def store(hash, key, block, path:)
          identity = [ hash.object_id, key ]
          if hash.key?(key) || @conflicts[identity]
            @conflicts[identity] = true
            hash.delete(key)
            @cursor.mark(@sources[identity].index, state: :invalid) if @sources[identity]
            issue(block, :duplicate_identity)
            return
          end
          @sources[identity] = block
          hash[key] = scope(block, path) { yield }
        rescue ArgumentError, IPAddr::Error
          @conflicts[identity] = true
          hash.delete(key)
          raise
        end

        # 忽略无关系统设置，但不将位置错误的已建模语法视为完整。
        def check_unhandled(block)
          if /\A(?:no )?(?:hostname|interface|vlan|vrf|router|vpc|evpn|feature|ip address|ip router ospf|ip access-group|ip prefix-list|ipv6 prefix-list|ip access-list|route-map|vn-segment|member vni|route-target|channel-group|fabric forwarding|mtu|ip unnumbered|ip ospf network|switchport mode|switchport access vlan|ip forward|ipv6 address)\b/.match?(block.text)
            issue(block)
          else
            @cursor.mark(block.index, state: :ignored)
          end
          block.children.each { |child| check_unhandled(child) }
        end

        # 忽略已知叶子语句时，不能隐藏其嵌套配置作用域。
        def ignore(block)
          @cursor.mark(block.index, state: :ignored)
          pending = block.children.dup
          until pending.empty?
            child = pending.pop
            issue(child)
            pending.concat(child.children)
          end
          nil
        end

        # 将稳定诊断代码关联到对应来源行。
        def issue(block, code = :unsupported_configuration)
          @issues << { code: code, line: block.line }
          source = code == :invalid_configuration_value ? (@invalid_source || block) : block
          state = code == :unsupported_configuration ? :unsupported : :invalid
          @cursor.mark(source.index, state: state)
        end

        # 已知叶子语句不能静默容纳另一条已建模配置命令。
        def unparsed_child(block) = check_unhandled(block)
      end
    end
  end
end
