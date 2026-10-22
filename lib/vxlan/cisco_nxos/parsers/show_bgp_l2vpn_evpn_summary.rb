# frozen_string_literal: true

require_relative "../parser"

module Vxlan
  module CiscoNxos
    module Parsers
      # 从 BGP 汇总解析 EVPN 邻居状态及可选路由类型统计。
      class ShowBgpL2vpnEvpnSummary < Parser
        EMPTY = "(?:BGP )?neighbors"
        IDENTITY = %i[vrf address_family peer_ip].freeze
        BOUNDARY = /^\s*BGP summary information for VRF /
        SCOPE = /\ABGP summary information for VRF (\S+), address family (.+)\z/
        ROUTER = /\ABGP router identifier (\S+), local AS number (\S+)\z/
        HEADER = /\ANeighbor\s+V\s+AS\s+MsgRcvd\s+MsgSent\s+TblVer\s+InQ\s+OutQ\s+Up\/Down\s+State\/PfxRcd\z/i
        ROW = /\A([\da-f:.]+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(.+)\z/i
        FIELDS = %i[peer_ip version remote_as messages_received messages_sent table_version input_queue output_queue uptime state].freeze
        INTEGERS = %i[version remote_as messages_received messages_sent table_version input_queue output_queue].freeze
        PREFIX_TYPES = %i[type1 type2 type3 type4 type5 type6 type7 type8 type12].freeze

        private

        # 重复物理输出段仍属于同一逻辑 VRF/AF；空表段也必须参与身份冲突检查。
        def parse_content(text, complete:)
          super
          scope, identities, invalid = nil, {}, {}
          text.each_line("\n") do |line|
            if (match = SCOPE.match(line.strip))
              scope = match.captures
            elsif (match = ROUTER.match(line.strip))
              identity = router_identity(match)
              if !identity
                invalid[scope] ||= :invalid_bgp_identity
              elsif identities.key?(scope) && identities[scope] != identity
                invalid[scope] ||= :conflicting_bgp_identity
              else
                identities[scope] = identity
              end
            end
          end
          invalid.each do |key, code|
            issue = { code: code, vrf: key&.first, address_family: key&.last }
            @issues << issue unless @issues.include?(issue)
          end
          @rows.reject! { |row| invalid.key?(row.values_at(:vrf, :address_family)) }
        end

        # ASDOT 与 ASPLAIN 用同一数值比较；无效身份不能附着到完整邻居事实。
        def router_identity(match)
          router, asn = match.captures
          return unless ip_address?(router) && IPAddr.new(router).ipv4? && asn.match?(/\A\d+(?:\.\d+)?\z/)
          parts = asn.split(".").map(&:to_i)
          return if parts.size == 2 && parts.any? { |part| !part.between?(0, 65_535) }
          number = parts.size == 2 ? parts.first * 65_536 + parts.last : parts.first
          [ IPAddr.new(router).to_s, number ] if number.between?(1, 4_294_967_295)
        end

        # 解析命令表格行，保留数量及格式错误行诊断。
        def parse_rows(text)
          scope, prefix_columns, prefix_seen, peers = {}, nil, {}, {}
          prefix_total = false
          each_content_line(text) do |line, number|
            if HEADER.match?(line)
              @header = true
            elsif (match = SCOPE.match(line))
              scope = { vrf: match[1], address_family: match[2] }
              unparsed_records(number) unless scope[:address_family] == "L2VPN EVPN"
              prefix_columns = nil
            elsif (match = ROUTER.match(line))
              scope.merge!(router_id: match[1], local_as: match[2])
            elsif (match = /\ANeighbor\s+T\s+AS\s+(?:(PfxRcd)\s+)?(Type-[1-9]\d*(?:\s+Type-[1-9]\d*)*)\z/.match(line))
              prefix_total = !match[1].nil?
              prefix_columns = match[2].split(" ").map { |column| column.downcase.delete("-").to_sym }
              if prefix_columns.uniq != prefix_columns || (prefix_columns - PREFIX_TYPES).any?
                unparsed_records(number)
                prefix_columns = nil
              end
            elsif prefix_columns
              words = line.split(" ")
              address = CtxParser::Values.ip_address(words[0], allow_zone: true) if ip_address?(words[0])
              peer = peers[[ scope[:vrf], scope[:address_family], address ]]
              offset = prefix_total ? 4 : 3
              if words.size == prefix_columns.size + offset && %w[I E].include?(words[1]) && words.drop(2).all? { |word| word.match?(/\A\d+\z/) } &&
                peer && peer[:prefixes_received] && !prefix_seen.key?(peer.object_id) && peer[:remote_as] == words[2].to_i &&
                (!prefix_total || peer[:prefixes_received] == words[3].to_i)
                counts = words.drop(offset).map(&:to_i)
                # 路由类型是总前缀的子集；未展示的类型允许存在，已展示之和不能超过总数。
                if counts.sum > peer[:prefixes_received]
                  @issues << { code: :inconsistent_prefix_statistics, line: number }
                else
                  peer[:prefixes_by_type] = prefix_columns.zip(counts).to_h
                end
                prefix_seen[peer.object_id] = true
              else
                unparsed_records(number)
              end
            elsif (match = ROW.match(line))
              row = FIELDS.zip(match.captures).to_h.merge(scope)
              INTEGERS.each { |key| row[key] = row[key].to_i }
              unless row[:vrf] && row[:address_family] == "L2VPN EVPN" && ip_address?(row[:peer_ip]) && row[:version] == 4 && (1..4_294_967_295).cover?(row[:remote_as]) &&
                row[:state].match?(/\A(?:\d+|Idle(?: \(Admin\))?|Active|Connect|OpenSent|OpenConfirm|Shutdown)\z/i)
                unparsed_records(number)
                next
              end
              row[:peer_ip] = CtxParser::Values.ip_address(row[:peer_ip], allow_zone: true)
              row[:state] = row[:state].downcase.tr(" ", "_")
              row[:prefixes_received] = row[:state].match?(/\A\d+\z/) ? row[:state].to_i : nil
              row[:state] = "established" if row[:prefixes_received]
              @rows << row
              # 统计表按完整作用域查找；重复邻居仍由最终身份检查整体隔离。
              peers[row.values_at(:vrf, :address_family, :peer_ip)] ||= row
            elsif !line.match?(/\A(?:BGP table version is \d+(?:, L2VPN EVPN config peers \d+, capable peers \d+)?|\d+ network entries and \d+ paths using \d+ bytes of memory|BGP attribute entries \[\d+\/\d+\], BGP AS path entries \[\d+\/\d+\]|BGP community entries \[\d+\/\d+\], BGP clusterlist entries \[\d+\/\d+\])\z/i)
              unparsed_records(number)
            end
          end
          if prefix_columns && prefix_seen.size != @rows.size
            @issues << { code: :missing_prefix_statistics, expected: @rows.size, observed: prefix_seen.size }
          end
        end

        # 归一化平台值，同时保留未知或不支持的状态。
        def normalize(text)
          output = []
          super.each_line("\n") do |line|
            if output.last&.strip&.end_with?("State/") && line.strip == "PfxRcd"
              output[-1] = output.last.rstrip + line.strip + "\n"
            else
              output << line
            end
          end
          output.join("")
        end
      end
    end
  end
end
