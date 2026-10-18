# frozen_string_literal: true

require "ctx_parser/document"
require "ctx_parser/banner"
require_relative "terminal"

module Vxlan
  module CiscoNxos
    # NX-OS 横幅始终作为词法文本处理，即使其正文看起来像命令。
    class Document < CtxParser::Document
      protected

      # 区分配置结构行与引号、横幅中的文本内容。
      def classify(line)
        @banner ||= CtxParser::Banner.new
        return :ignored if @banner.consume(line.text)

        if Terminal.invalid_output?(line.raw, allow_cr_newlines: true)
          issues << { code: :incomplete_configuration, line: line.number }
          return :ignored
        end

        super
      end

      # 报告配置文档结束时仍未闭合的横幅。
      def finish
        issues.each { |issue| cursor.mark(issue.fetch(:line) - 1, state: :invalid) }
        issues << { code: :incomplete_banner } if @banner&.open?
      end
    end
  end
end
