# frozen_string_literal: true

require_relative "../parser"

module Vxlan
  module CiscoNxos
    module Parsers
      # 解析 MAC 表记录，将网关条目保留为独立身份。
      class ShowMacAddressTable < Parser
        EMPTY = "(?:MAC addresses|entries)".freeze

        private

        # 解析当前命令的记录，保留无法识别行的诊断。
        def parse_rows(text)
          each_content_line(text) do |line, number|
            if line.match?(/\AVLAN\s+MAC Address\s+Type\s+age\s+Secure\s+NTFY\s+Ports\z/i)
              @header = true
            elsif (match = /\A(?:[*+GOCR~]\s+)?(\d+|-)\s+([\da-f]{4}(?:\.[\da-f]{4}){2})\s+(dynamic|static)\s+(\S+)\s+([TF])\s+([TF])\s+(.+)\z/i.match(line))
              unless match[1] == "-" || (1..4094).cover?(match[1].to_i)
                unparsed_records(number)
                next
              end
              @rows << { vlan_id: match[1] == "-" ? nil : match[1].to_i, mac: CtxParser::Values.mac_address(match[2]),
                type: match[3].downcase, age: match[4], secure: match[5].upcase == "T", notify: match[6].upcase == "T", destination: match[7],
                flags: line[/\A([*+GOCR~])\s+/, 1] }
            elsif !line.match?(/\A(?:Legend:|\* - primary entry, G - Gateway MAC, \(R\) - Routed MAC, O - Overlay MAC|age - seconds since last seen,\+ - primary entry using vPC Peer-Link,|\(T\) - True, \(F\) - False, C - ControlPlane MAC, ~ - vsan,?|\(NA\)- Not Applicable(?: A [–-] ESI Active Path, S [–-] ESI Standby Path)?|TL - True Learned, PS - Peer Sync, RO - Re-originate)\z/i)
              unparsed_records(number)
            end
          end
          exclude_ambiguous_records!(@rows, %i[vlan_id mac]) do |row|
            identity = row.values_at(:vlan_id, :mac)
            if row[:flags] == "G" && row[:type] == "static" && row[:destination].match?(/\A(?:sup-eth\d+\(R\)|(Lo\d+)\(R\)(?: \(\1\))?)\z/i)
              identity.concat([ :gateway, row[:destination] ])
            end
            identity
          end
        end
      end
    end
  end
end
