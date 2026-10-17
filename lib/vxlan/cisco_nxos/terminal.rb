# frozen_string_literal: true

module Vxlan
  module CiscoNxos
    # 分页及终端编辑控制会破坏事实边界；保留正常换行和制表符。
    module Terminal
      INVALID = /--[ \t]*More[ \t]*--|[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/i
      private_constant :INVALID

      # 检查原始正文，避免 strip 或字段解析先吞掉控制字符。
      def self.invalid_output?(text) = INVALID.match?(text)
    end
  end
end
