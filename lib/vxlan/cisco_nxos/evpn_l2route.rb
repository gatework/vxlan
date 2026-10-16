# frozen_string_literal: true

require_relative "parser"

module Vxlan
  module CiscoNxos
    # 按声明列解析 MAC、MAC-IP 行，仅将续行关联到已确认的前一条路由。
    class EvpnL2route < Parser
      UINT32 = 0..4_294_967_295
      LABELS = { "topology" => :topology_id, "topology id" => :topology_id, "mac address" => :mac,
        "host ip" => :host_ip, "prod" => :producer, "flags" => :flags, "seq no" => :sequence,
        "next-hops" => :next_hops, "next hop (s)" => :next_hops, "next hop(s)" => :next_hops }.freeze
      HEADER = /Topology ID|Topology|Mac Address|Host IP|Prod|Flags|Seq No|Next-Hops|Next Hop \(s\)|Next Hop\(s\)/i

      private

      # 解析命令表格行，保留数量及格式错误行诊断。
      def parse_rows(text)
        type = self.class::TYPE
        @totals = []
        fields = previous = nil
        text.each_line.with_index(1) do |source, number|
          line = source.strip
          next if line.empty? || line.match?(/\A[-=\s]+\z/) || line.match?(/\A(?:Flags\s*-\s*)?(?:\([A-Za-z0-9]+\):[A-Za-z0-9 ,\/-]+\s*)+\z/)
          if line.match?(/\ATopology\b/i)
            labels = line.gsub(/\s+/, " ").scan(HEADER)
            fields = labels.map { |label| LABELS.fetch(label.downcase) }
            required = %i[topology_id mac producer next_hops] + (type == :mac_ip ? [ :host_ip ] : [])
            unless line.gsub(/\s+/, " ").gsub(HEADER, "").strip.empty? && fields.uniq == fields &&
              (required - fields).empty? && (fields - required - %i[flags sequence]).empty? &&
              fields.first(2) == %i[topology_id mac] && fields.last == :next_hops
              fields = nil
              @issues << { code: :unknown_header, line: number }
            end
            previous = nil
          elsif line.match?(/\ANo (?:MAC(?:-IP)? )?(?:routes|entries)(?: found)?\.?\z/i)
            @empty = true
            previous = nil
          elsif (match = /\ATotal (?:number of )?(?:MAC(?:-IP)? )?(?:routes|entries)(?: displayed)?\s*:\s*(\d+)\z/i.match(line))
            @totals << match[1].to_i
            previous = nil
          else
            begin
              if fields && line.match?(/\A\d+\s/)
                values = line.split(/\s+/, fields.size)
                raise ArgumentError unless values.size == fields.size
                previous = route(fields.zip(values).to_h, type)
                @rows << previous
              elsif previous && source.match?(/\A\s+/)
                previous[:next_hops] = (previous[:next_hops] + next_hops(line)).uniq
              else
                raise ArgumentError
              end
            rescue ArgumentError, IPAddr::Error
              previous = nil
              @issues << { code: :unparsed_row, line: number }
            end
          end
        end
      end

      # 汇总已解析记录，并报告未解决或不完整的来源状态。
      def finish(complete)
        @totals.each { |count| mismatch(count, @rows.size) }
        remove_duplicates(@rows, %i[topology_id mac host_ip producer])
        @issues << { code: :contradictory_empty } if @empty && @rows.any?
        @issues << { code: :missing_completeness_evidence } if @rows.empty? && !@empty && @totals != [ 0 ]
        @issues << { code: :output_incomplete } unless complete
        CtxParser::Result.new(status: @issues.empty? ? :complete : :partial, records: @rows, issues: @issues)
      end

      # 归一化单条 EVPN 路由及回显的身份字段。
      def route(values, type)
        values[:topology_id] = number(values[:topology_id])
        raise ArgumentError unless values[:mac].match?(/\A(?:[0-9a-f]{4}(?:\.[0-9a-f]{4}){2}|(?:[0-9a-f]{2}:){5}[0-9a-f]{2})\z/i)
        values[:mac] = CtxParser::Values.mac(values[:mac])
        values[:sequence] = number(values[:sequence]) if values[:sequence]
        values[:host_ip] = host(values.fetch(:host_ip)) if type == :mac_ip
        values[:next_hops] = next_hops(values.fetch(:next_hops))
        values
      end

      # 归一化 EVPN 路由关联的全部下一跳。
      def next_hops(text)
        result = []
        until text.empty?
          match = /\A(?<hop>Ifindex\s+\d+|Local|(?:Eth(?:ernet)?|Po(?:rt-channel)?|nve|Lo(?:opback)?|Vlan|vPC)[\d\/.:-]+|[\da-f:.]+)(?:\s*\(Label:\s*(?<label>\d+)\))?(?=\s|,|\z)/i.match(text)
          raise ArgumentError unless match
          token = match[:hop]
          value = case token
          when /\ALocal\z/i then { local: true }
          when /\AIfindex\s+(\d+)\z/i then { ifindex: number($1) }
          when /\A(?:Eth|Po|nve|Lo|Vlan|vPC)/i then { interface: token }
          else { address: host(token) }
          end
          value[:label] = number(match[:label]) if match[:label]
          result << value
          remainder = text[match.end(0)..]
          break if remainder.empty?
          text = remainder.sub(/\A(?:\s*,\s*|\s+)/, "")
          raise ArgumentError if text.empty? || text.start_with?(",")
        end
        raise ArgumentError if result.empty?
        result
      end

      # 解析数值测量，不将未知文本转换为零。
      def number(value)
        CtxParser::Values.integer(value, max: UINT32.end)
      end

      # 归一化主机地址，保留 IPv4 与 IPv6 语义。
      def host(value)
        CtxParser::Values.host(value, allow_zone: true)
      end
    end
  end
end
