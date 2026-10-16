# frozen_string_literal: true

require_relative "../parser"

module Vxlan
  module CiscoNxos
    module Parsers
      # 解析 NVE 端点及路由器 MAC，支持终端换行记录。
      class ShowNvePeers < Parser
        EMPTY = "peers"
        IDENTITY = %i[interface peer_ip].freeze
        HEADER = /\AInterface\s+Peer-IP\s+State\s+LearnType\s+Uptime\s+Router-Mac\z/i
        ROW = /\A(nve\d+)\s+(\d+(?:\.\d+){3})\s+(Up|Down)\s+(\S+)\s+(\S+)\s+([\da-f]{4}(?:\.[\da-f]{4}){2})\z/i
        FIELDS = %i[interface peer_ip state learn_type uptime router_mac].freeze

        private

        # 解析命令表格行，保留数量及格式错误行诊断。
        def parse_rows(text)
          lines(text) do |line, number|
            if HEADER.match?(line)
              @header = true
            elsif (match = ROW.match(line)) && valid_host?(match[2])
              @rows << FIELDS.zip(match.captures).to_h.merge(state: match[3].downcase)
            else
              reject(number)
            end
          end
        end

        # 归一化平台值，同时保留未知或不支持的状态。
        def normalize(text)
          output = []
          super.each_line do |line|
            tail, previous = line.strip, output.last&.strip
            header = previous && previous.end_with?("Route") && tail == "r-Mac"
            mac = previous && tail.match?(/\A[\da-f]{4}\.[\da-f]{4}\z/i) && previous.match?(/\Anve\d+\s+\d+(?:\.\d+){3}\s+(?:Up|Down)\s+\S+\s+\S+\s+[\da-f]{4}\.\z/i)
            if header || mac
              output[-1] = output.last.rstrip + tail + "\n"
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
