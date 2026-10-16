# frozen_string_literal: true

require_relative "../parser"

module Vxlan
  module CiscoNxos
    module Parsers
      # 解析 port-channel 汇总，保留成员状态与明确数量证据。
      class ShowPortChannelSummary < Parser
        EMPTY = "port-channels".freeze
        IDENTITY = %i[group].freeze

        private

        # 解析当前命令的记录，保留无法识别行的诊断。
        def parse_rows(text)
          totals = []
          lines(text) do |line, number|
            if line.match?(/\AGroup\s+Port-(?:Channel)?\s+Type\s+Protocol\s+Member Ports\z/i)
              @header = true
            elsif line == "Channel" && @header
              next
            elsif (match = /\A(\d+)\s+(Po\d+)\(([^\s()]+)\)\s+(\S+)\s+(\S+)\s*(.*)\z/i.match(line))
              @rows << { group: match[1].to_i, interface: match[2], flags: match[3], type: match[4], protocol: match[5], members: members(match[6]) }
            elsif line.match?(/\A(?:Eth(?:ernet)?\S+\([^)]+\)\s*)+\z/i) && @rows.any?
              @rows.last[:members].concat(members(line))
            elsif (match = /\ANumber of port-channels\s*:\s*(\d+)\z/i.match(line))
              totals << match[1].to_i
            elsif !line.match?(/\A(?:Flags:\s+D - Down\s+P - Up in port-channel \(members\)|I - Individual\s+H - Hot-standby \(LACP only\)|s - Suspended\s+r - Module-removed|b - BFD Session Wait|S - Switched\s+R - Routed|U - Up \(port-channel\)|p - Up in delay-lacp mode \(member\)|M - Not in use\. Min-links not met)\z/)
              reject(number)
            end
          end
          totals.each { |total| mismatch(total, @rows.size) }
          @empty = true if totals == [ 0 ] && @rows.empty?
        end

        # 将回显的聚合成员归一化为接口身份及状态标志。
        def members(text)
          return [] if text.empty? || text == "--"
          text.split.filter_map do |word|
            match = /\A(Eth(?:ernet)?[\d\/]+)\(([^\s()]+)\)\z/i.match(word)
            @issues << { code: :invalid_port_channel_member } unless match
            { interface: match[1], flags: match[2] } if match
          end
        end
      end
    end
  end
end
