# frozen_string_literal: true

require_relative "../parser"

module Vxlan
  module CiscoNxos
    module Parsers
      # 根据响应表头解释接口汇总列。
      class ShowInterfaceBrief < Parser
        EMPTY = "interfaces".freeze
        IDENTITY = %i[interface].freeze
        INTERFACE = /\A(?:mgmt\d+|Eth(?:ernet)?\d[\w\/.-]*|Po\d+|port-channel\d+|Vlan\d+|Lo\d+|loopback\d+|nve\d+)\z/i

        private

        # 解析当前命令的记录，保留无法识别行的诊断。
        def parse_rows(text)
          layout = nil
          each_content_line(text) do |line, number|
            if line.match?(/\A(?:Port\s+VRF\s+Status\s+IP Address(?:\s+Speed\s+MTU)?|(?:Port|Interface)\s+Name\s+Status\s+Vlan\s+Duplex\s+Speed\s+Type|(?:Ethernet|Port-channel)\s+VLAN\s+Type\s+Mode\s+Status\s+Reason\s+Speed\s+(?:Port|Protocol)|Interface\s+Status\s+Description|Interface\s+Secondary VLAN\(Type\)\s+Status Reason|Port\s+Status Reason\s+MTU)\z/i)
              layout = line
              @header = true
            elsif line.match?(/\AInterface(?:\s+Ch #)?\z/i)
              next
            else
              words = line.split(" ")
              state = words.index { |word| %w[up down connected notconnect disabled admin-down].include?(word.downcase) }
              unless layout && state && INTERFACE.match?(words[0])
                unparsed_records(number)
                next
              end
              row = { interface: words[0], state: words[state].downcase, detail: words.drop(state + 1).join(" ") }
              case layout
              when /\APort\s+VRF/i
                if state == 2 && [ 4, 6 ].include?(words.size) && (words.size == 4 || words[5].match?(/\A\d+\z/)) &&
                  (words[3] == "--" || ip_address?(words[3]))
                  row.merge!(vrf: words[1], ip_address: words[3])
                  row.merge!(speed: words[4], mtu: words[5].to_i) if words.size == 6
                else
                  unparsed_records(number)
                  next
                end
              when /\A(?:Ethernet|Port-channel)\s+VLAN/i
                unless state == 4 && words.size >= 8
                  unparsed_records(number)
                  next
                end
                row.merge!(vlan: words[1], type: words[2], mode: words[3], reason: words[5...-2].join(" "), speed: words[-2])
                row[layout.start_with?("Ethernet") ? :port_channel : :protocol] = words[-1]
              when /\AInterface\s+Status/i
                unless state == 1
                  unparsed_records(number)
                  next
                end
                row[:description] = words.drop(2).join(" ")
              when /\AInterface\s+Secondary/i
                unless state >= 2
                  unparsed_records(number)
                  next
                end
                row.merge!(secondary_vlan: words[1...state].join(" "), reason: words.drop(state + 1).join(" "))
              when /\APort\s+Status Reason/i
                unless state == 1 && words.size >= 4 && words.last.match?(/\A\d+\z/)
                  unparsed_records(number)
                  next
                end
                row.merge!(reason: words[2...-1].join(" "), mtu: words.last.to_i)
              else
                match = /\A\S+\s+(.*?)\s+(connected|notconnect|disabled|admin-down|up|down)\s+(\d+|routed|trunk|unassigned|--)\s+(full|half|a-full|a-half|auto|--)\s+(\S+)\s+(.+)\z/i.match(line)
                unless match
                  unparsed_records(number)
                  next
                end
                row.merge!(name: match[1], state: match[2].downcase, vlan: match[3], duplex: match[4], speed: match[5], type: match[6],
                  detail: match.captures.drop(2).join(" "))
              end
              @rows << row
            end
          end
        end
      end
    end
  end
end
