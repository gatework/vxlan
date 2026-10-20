# frozen_string_literal: true

require_relative "../parser"

module Vxlan
  module CiscoNxos
    module Parsers
      # 从 show nve vni 解析 VNI 身份、关联关系及 NX-OS 标志。
      class ShowNveVni < Parser
        EMPTY = "VNIs"
        IDENTITY = %i[interface vni].freeze
        HEADER = /\AInterface\s+VNI\s+Multicast-group\s+State\s+Mode\s+Type\s+\[BD\/VRF\](?:\s+Flags)?\z/i
        ROW = /\A(nve\d+)\s+(\d+)\s+(\S+)\s+(Up|Down)\s+(\S+)\s+(L[23])\s+\[([^\]]+)\](?:\s+(\S+))?\z/i
        FIELDS = %i[interface vni multicast_group state mode type association flags].freeze

        private

        # 解析命令表格行，保留数量及格式错误行诊断。
        def parse_rows(text)
          each_content_line(text) do |line, number|
            if HEADER.match?(line)
              @header = true
            elsif (match = ROW.match(line))
              row = FIELDS.zip(match.captures).to_h.compact
              row[:vni] = row[:vni].to_i
              unless (1..16_777_215).cover?(row[:vni]) && multicast_group?(row[:multicast_group]) &&
                  (!row[:flags] || %w[SA S-ND SU Xconn MS-IR HYB].include?(row[:flags]))
                unparsed_records(number)
                next
              end
              @rows << row.merge(state: row[:state].downcase, type: row[:type].downcase)
            elsif !line.gsub(/\s+/, " ").match?(/\A(?:Codes: CP - Control Plane DP - Data Plane|UC - Unconfigured SA - Suppress ARP|S-ND - Suppress ND|SU - Suppress Unknown Unicast|Xconn - Crossconnect|MS-IR - Multisite Ingress Replication|HYB - Hybrid IRB mode)\z/)
              unparsed_records(number)
            end
          end
        end

        # 此列也承载单播复制标记；其余值必须是 IPv4 组播主机地址。
        def multicast_group?(value)
          return true if %w[UnicastBGP UnicastStatic n/a].include?(value)

          ip_address?(value) && IPAddr.new("224.0.0.0/4").include?(value)
        end
      end
    end
  end
end
