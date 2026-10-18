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
        HEADER = /\ANeighbor\s+V\s+AS\s+MsgRcvd\s+MsgSent\s+TblVer\s+InQ\s+OutQ\s+Up\/Down\s+State\/PfxRcd\z/i
        ROW = /\A([\da-f:.]+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(.+)\z/i
        FIELDS = %i[peer_ip version remote_as messages_received messages_sent table_version input_queue output_queue uptime state].freeze
        INTEGERS = %i[version remote_as messages_received messages_sent table_version input_queue output_queue].freeze

        private

        # 解析命令表格行，保留数量及格式错误行诊断。
        def parse_rows(text)
          scope, prefix_columns, prefix_seen, peers = {}, nil, {}, {}
          each_content_line(text) do |line, number|
            if HEADER.match?(line)
              @header = true
            elsif (match = /\ABGP summary information for VRF (\S+), address family (.+)/.match(line))
              scope = { vrf: match[1], address_family: match[2] }
              prefix_columns = nil
            elsif (match = /\ABGP router identifier (\S+), local AS number (\S+)/.match(line))
              scope.merge!(router_id: match[1].delete_suffix(","), local_as: match[2])
              unparsed_records(number) unless ip_address?(scope[:router_id]) && scope[:local_as].match?(/\A\d+(?:\.\d+)?\z/)
            elsif line.match?(/\ANeighbor\s+T\s+AS\s+PfxRcd\s+Type-2\s+Type-3\s+Type-4\s+Type-5(?:\s+Type-12)?\z/)
              prefix_columns = line.end_with?("Type-12") ? %i[type2 type3 type4 type5 type12] : %i[type2 type3 type4 type5]
            elsif prefix_columns
              words = line.split
              peer = peers[[ scope[:vrf], scope[:address_family], words[0] ]]
              if words.size == prefix_columns.size + 4 && %w[I E].include?(words[1]) && words.drop(2).all? { |word| word.match?(/\A\d+\z/) } &&
                peer && !prefix_seen.key?(peer.object_id) && peer[:remote_as] == words[2].to_i && peer[:prefixes_received] == words[3].to_i
                peer[:prefixes_by_type] = prefix_columns.zip(words.drop(4).map(&:to_i)).to_h
                prefix_seen[peer.object_id] = true
              else
                unparsed_records(number)
              end
            elsif (match = ROW.match(line))
              row = FIELDS.zip(match.captures).to_h.merge(scope)
              INTEGERS.each { |key| row[key] = row[key].to_i }
              unless ip_address?(row[:peer_ip]) && row[:version] == 4 && (1..4_294_967_295).cover?(row[:remote_as]) &&
                row[:state].match?(/\A(?:\d+|Idle(?: \(Admin\))?|Active|Connect|OpenSent|OpenConfirm|Shutdown)\z/i)
                unparsed_records(number)
                next
              end
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
          super.each_line do |line|
            if output.last&.strip&.end_with?("State/") && line.strip == "PfxRcd"
              output[-1] = output.last.rstrip + line.strip + "\n"
            else
              output << line
            end
          end
          output.join
        end
      end
    end
  end
end
