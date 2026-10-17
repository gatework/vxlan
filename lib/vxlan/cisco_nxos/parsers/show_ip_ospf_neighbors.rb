# frozen_string_literal: true

require_relative "../parser"

module Vxlan
  module CiscoNxos
    module Parsers
      # 逐进程、VRF 独立核对 OSPF 邻居总数。
      class ShowIpOspfNeighbors < Parser
        EMPTY = "(?:OSPF )?neighbors"
        IDENTITY = %i[process vrf neighbor_id interface].freeze
        BOUNDARY = /^\s*OSPF Process ID /
        HEADER = /\ANeighbor ID\s+Pri\s+State\s+Up Time\s+Address\s+Interface\z/i
        ROW = /\A([\d.]+)\s+(\d+)\s+(\S+(?:\/\s*\S+)?)\s+(\S+)\s+([\d.]+)\s+(\S+)\z/
        FIELDS = %i[neighbor_id priority state uptime address interface].freeze

        private

        # 解析命令表格行，保留数量及格式错误行诊断。
        def parse_rows(text)
          scope, totals = {}, []
          lines(text) do |line, number|
            if HEADER.match?(line)
              @header = true
            elsif (match = /\AOSPF Process ID (\S+) VRF (\S+)\z/i.match(line))
              scope = { process: match[1], vrf: match[2] }
            elsif (match = /\ATotal number of neighbors:\s*(\d+)\z/i.match(line))
              totals << match[1].to_i
            elsif (match = ROW.match(line))
              row = FIELDS.zip(match.captures).to_h.merge(scope)
              row[:priority] = row[:priority].to_i
              unless ip_address?(row[:neighbor_id]) && ip_address?(row[:address]) && (0..255).cover?(row[:priority]) &&
                row[:state].match?(/\A(?:DOWN|ATTEMPT|INIT|2WAY|EXSTART|EXCHANGE|LOADING|FULL)\/(?:\s*(?:DR|BDR|DROTHER|-))\z/i)
                reject(number)
                next
              end
              @rows << row.merge(state: row[:state].downcase.delete(" "))
            else
              reject(number)
            end
          end
          totals.each { |count| mismatch(count, @rows.size) }
          @empty = true if @rows.empty? && totals == [ 0 ]
        end
      end
    end
  end
end
