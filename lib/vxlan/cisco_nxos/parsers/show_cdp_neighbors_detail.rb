# frozen_string_literal: true

require_relative "../parser"

module Vxlan
  module CiscoNxos
    module Parsers
      # 在所属邻居记录内解释 CDP 详细字段。
      class ShowCdpNeighborsDetail < Parser
        EMPTY = "(?:CDP neighbors|CDP entries|neighbors|entries)".freeze
        IDENTITY = %i[device_id interface neighbor_interface].freeze

        private

        # 解析当前命令的记录，保留无法识别行的诊断。
        def parse_rows(text)
          row, scope, totals = nil, nil, []
          each_content_line(text, separators: true) do |line, number|
            if line.match?(/\A[-=+\s]+\z/)
              scope = nil
              next
            end
            if (match = /\ATotal (?:entries|cdp entries) displayed\s*:\s*(\d+)\z/i.match(line))
              totals << match[1].to_i
              scope = nil
              next
            end
            if (match = /\ADevice ID:\s*(\S.*)\z/i.match(line))
              @rows << row if row
              row = { device_id: match[1], interface_addresses: [], management_addresses: [], attributes: {} }
              scope = nil
              @header = true
              next
            end
            unless row
              unparsed_records(number)
              next
            end
            case line
            when /\A--More--/i then unparsed_records(number)
            when /\ASystem Name:\s*(\S.*)\z/i then row[:neighbor_name] = $1
            when /\AInterface address\(es\):(?:\s+\d+)?\z/i then scope = :interface_addresses
            when /\AMgmt address\(es\):(?:\s+\d+)?\z/i then scope = :management_addresses
            when /\AIP(?:v[46])? Address:\s*(\S+)\z/i
              value = $1
              if %i[interface_addresses management_addresses].include?(scope) && ip_address?(value)
                row[scope] << IPAddr.new(value).to_s
              else
                unparsed_records(number)
              end
            when /\APlatform:\s*(.+?),\s*Capabilities:\s*(.+)\z/i
              row.merge!(platform: $1, capabilities: $2)
              scope = nil
            when /\AInterface:\s*(\S+),\s*Port ID \(outgoing port\):\s*(\S.*)\z/i
              unparsed_records(number) if row.key?(:interface)
              row.merge!(interface: $1, neighbor_interface: $2)
              scope = nil
            when /\AHoldtime:\s*(\d+) sec\z/i then row[:holdtime] = $1.to_i
            when /\AVersion:\z/i
              scope = :version
              row[:version] = ""
            when /\A((?:Local|Remote) Interface MAC):\s*([\da-f]{2}(?::[\da-f]{2}){5})\z/i
              row[:attributes][$1.downcase.tr(" ", "_").to_sym] = $2.downcase
              scope = nil
            when /\A(Advertisement Version|Duplex|MTU|Native VLAN|VTP Management Domain|Physical Location|DC_UUID):\s*(.+)\z/i
              row[:attributes][$1.downcase.tr(" ", "_").to_sym] = $2
              scope = nil
            else
              scope == :version ? row[:version] = [ row[:version], line ].reject(&:empty?).join("\n") : unparsed_records(number)
            end
          end
          @rows << row if row
          totals.each { |total| count_mismatch(total, @rows.size) }
          @empty = true if totals == [ 0 ] && @rows.empty?
          @rows.reject! do |entry|
            entry[:neighbor_name] ||= entry[:device_id].sub(/\([^)]*\)\z/, "").split(".").first
            if entry.values_at(:neighbor_name, :interface, :neighbor_interface).any? { |value| value.nil? || value.empty? }
              @issues << { code: :incomplete_cdp_neighbor }
              true
            end
          end
        end
      end
    end
  end
end
