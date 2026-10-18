# frozen_string_literal: true

require "ctx_parser/parser"
require "ctx_parser/records"
require "ctx_parser/input"
require "ctx_parser/values"
require_relative "terminal"

module Vxlan
  module CiscoNxos
    # NX-OS 清单完整要求格式、空表证据与采集完整性均经过校验。
    class Parser < CtxParser::Parser
      EMPTY = nil
      IDENTITY = nil
      BOUNDARY = nil
      UNSUPPORTED = /^\s*(?:%\s*)?(?:Invalid (?:command|input)\b.*|(?:This command is )?not supported\.?|(?:ERROR:\s*)?Feature\b.*not enabled\.?)\s*$/i

      private

      # 解释当前命令回显，保留不支持或格式错误的证据。
      def parse_output(text, complete:)
        begin
          text = CtxParser::Input.text(text, allow_nul: true)
        rescue EncodingError
          return CtxParser::Result.new(status: :partial, issues: [ { code: :invalid_encoding } ])
        end
        if Terminal.invalid_output?(text)
          line = text.each_line.with_index(1).find { |source, _number| Terminal.invalid_output?(source) }.last
          return CtxParser::Result.new(status: :partial, issues: [ { code: :invalid_terminal_output, line: line } ])
        end
        if self.class::UNSUPPORTED&.match?(text)
          return CtxParser::Result.new(status: :unsupported, issues: [ { code: :command_unsupported } ])
        end

        @issues, @rows, @empty, @header = [], [], false, false
        parse_content(normalize(text), complete: complete)
        finish(complete)
      end

      # 解析 NX-OS 表格前，先归一化终端回车符。
      def normalize(text) = CtxParser::Input.text(text, newlines: :delete_cr, allow_nul: true)

      # 分别解析各路由作用域，或分派单个命令表。
      def parse_content(text, complete:)
        return if self.class::BOUNDARY && parse_scopes(text, complete: complete)

        parse_rows(text)
      end

      # 汇总已解析记录，并报告未解决或不完整的来源状态。
      def finish(complete)
        @issues << { code: :missing_completeness_evidence } if @rows.empty? && !@empty
        @issues << { code: :format_unrecognized } unless @header || @empty
        @issues << { code: :contradictory_empty } if @empty && @rows.any?
        @issues << { code: :output_incomplete } unless complete
        exclude_ambiguous_records!(@rows, self.class::IDENTITY) if self.class::IDENTITY
        CtxParser::Result.new(status: @issues.empty? ? :complete : :partial, records: @rows, issues: @issues)
      end

      # 逐 VRF、进程独立检查，避免完整表掩盖同级表截断。
      def parse_scopes(text, complete:)
        blocks = text.split(/(?=#{self.class::BOUNDARY})/).reject { |block| block.strip.empty? }
        return false unless blocks.size > 1

        results = blocks.map { |block| self.class.parse(block, complete: complete) }
        @rows = results.flat_map(&:records)
        @issues = results.flat_map(&:issues)
        @header = results.all?(&:complete?) || @rows.any?
        @empty = results.all? { |result| result.complete? && result.records.empty? }
        true
      end

      # 逐行提供有效表格内容，并记录明确空表证据。
      def each_content_line(text, separators: false)
        text.each_line.with_index(1) do |source, number|
          line = source.strip
          next if line.empty? || (!separators && line.match?(/\A[-=+\s]+\z/))
          if self.class::EMPTY && line.match?(/\A(?:No #{self.class::EMPTY}(?: found)?|0 #{self.class::EMPTY})\.?\z/i)
            @empty = true
            next
          end
          yield line, number
        end
      end

      # 记录声明总数与实际解析数量不一致的情况。
      def count_mismatch(expected, observed)
        @issues << { code: :count_mismatch, expected: expected, observed: observed } unless expected == observed
      end

      # 追加行诊断；调用方负责决定是否继续处理当前记录。
      def unparsed_records(number)
        @issues << { code: :unparsed_row, line: number }
      end

      # 校验主机地址有效性，不让格式错误值继续传播。
      def ip_address?(value)
        CtxParser::Values.ip_address?(value, allow_zone: true)
      end

      # 原地排除重复身份的全部记录，不选取其中任意一条。
      def exclude_ambiguous_records!(rows, fields, &identity)
        identities = CtxParser::Records.new(rows, identity: fields, &identity)
        return unless identities.duplicates?
        rows.replace(identities.unambiguous)
        @issues << { code: :duplicate_identity, count: identities.duplicate_identity_count }
      end
    end
  end
end
