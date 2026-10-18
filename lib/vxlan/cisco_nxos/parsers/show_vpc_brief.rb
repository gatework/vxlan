# frozen_string_literal: true

require_relative "../parser"

module Vxlan
  module CiscoNxos
    module Parsers
      # 保留 vPC 域属性、peer-link 证据及成员状态。
      class ShowVpcBrief < Parser
        private

        # 解析当前命令的记录，保留无法识别行的诊断。
        def parse_rows(text)
          values, section = { attributes: {}, peer_links: [], members: [] }, nil
          labels = { "vPC domain id" => :domain_id, "Peer status" => :peer_status, "vPC keep-alive status" => :keepalive_status,
            "Configuration consistency status" => :consistency_status, "vPC role" => :role }
          each_content_line(text) do |line, number|
            if line.match?(/\Aid\s+Port\s+Status\s+Active vlans\z/i)
              section = :peer_links
            elsif line.match?(/\Aid\s+Port\s+Status\s+Consistency\s+Reason\s+Active vlans\z/i)
              section = :members
            elsif (match = /\A(\d+)\s+(Po\d+)\s+(up|down)\s+(.+)\z/i.match(line)) && section
              row = { id: match[1].to_i, interface: match[2], state: match[3].downcase }
              rest = match[4].split(/\s{2,}/)
              if section == :members
                member = /\A(\S+)\s+(.+?)\s{2,}([\d, .-]+)\z/.match(match[4])
                unless member
                  unparsed_records(number)
                  next
                end
                row.merge!(consistency: member[1], reason: member[2], active_vlans_summary: member[3])
              elsif match[4].match?(/\A[\d, .-]+\z/)
                row[:active_vlans_summary] = rest.join
              else
                unparsed_records(number)
                next
              end
              values[section] << row
            elsif section && values[section].any? && line.match?(/\A[\d,.-]+\z/)
              values[section].last[:active_vlans_summary] += line
            elsif line == "Legend:"
              next
            elsif line.include?(":")
              label, value = line.split(":", 2).map(&:strip)
              key = labels[label]
              if key
                @header = true
                if values.key?(key) || value.empty? || (key == :domain_id && !(value.match?(/\A\d+\z/) && (1..1000).cover?(value.to_i)))
                  unparsed_records(number)
                else
                  values[key] = key == :domain_id ? value.to_i : value
                end
              elsif label.match?(/\A(?:Per-vlan consistency status|Type-2 consistency status|Number of vPCs configured|Peer Gateway|Dual-active excluded VLANs|Graceful Consistency Check|Auto-recovery status|Delay-restore(?: SVI| Orphan-port)? status|Operational Layer3 Peer-router|Virtual-peerlink mode)\z/) && !value.empty?
                unparsed_records(number) if values[:attributes].key?(label)
                values[:attributes][label] = value
              else
                unparsed_records(number)
              end
            elsif !line.match?(/\A(?:vPC Peer-link status|vPC status|Legend:|\(\*\) - local vPC is down, forwarding via vPC peer-link|Please check "show vpc consistency-parameters vpc <vpc-num>" for the|consistency reason of down vpc and for type-2 consistency reasons for|any vpc\.)\z/i)
              unparsed_records(number)
            end
          end
          return unless @header
          missing = %i[domain_id peer_status keepalive_status consistency_status] - values.keys
          @issues << { code: :missing_vpc_fields, fields: missing } if missing.any?
          values.values_at(:peer_links, :members).flatten.each { |row| row[:active_vlans_truncated] = row[:active_vlans_summary].include?("...") }
          count = values[:attributes]["Number of vPCs configured"]
          if count
            count.match?(/\A\d+\z/) ? count_mismatch(count.to_i, values[:members].size) : @issues << { code: :invalid_vpc_count }
          end
          %i[peer_links members].each { |key| exclude_ambiguous_records!(values[key], [ :id ]) }
          @rows << values
        end
      end
    end
  end
end
