# frozen_string_literal: true

require "ctx_cli/command"
require "ctx_cli/review"
require "yaml"
require "ipaddr"
require "ctx_runner/evidence"
require_relative "report"

module Vxlan
  module CLI
    # 只读打开已有批次，生成独立建议批次；不加载凭据或建立设备连接。
    class Review
      # 注入输出流，离线批次可通过 CLI 或宿主调用。
      def initialize(out: $stdout, error: $stderr)
        @out, @error = out, error
      end

      # 返回零只代表建议生成完成，不代表问题已修复或候选配置已获批准。
      def run(argv)
        command = CtxCli::Command.new(banner: "用法：vxlan review --batch DIR [--output DIR]（离线生成建议，不执行配置）", out: @out) do |p, options|
          p.on("--fabric-policy FILE", "显式 Fabric/Leaf/Border/Spine 清单 YAML") { |value| options[:fabric_policy] = value }
          p.on("--batch DIR", "已采集批次，含 evidence/*.json") { |value| options[:batch] = value }
          p.on("--[no-]scripts", "可选导出配置建议，默认仅诊断") { |value| options[:scripts] = value }
          p.on("--output DIR", "私有输出根目录，默认批次内 reviews") { |value| options[:output] = value }
          p.on("-h", "--help", "查看帮助") { options[:help] = true }
        end
        CtxCli::Review.new(command: command, directory: "evidence", adapter: self, out: @out, error: @error).run(argv)
      end

      # 领域结构、建议和身份冲突必须在创建输出目录前全部校验。
      def prepare(documents, options)
        documents.each do |entry|
          validate(entry[2])
          entry << Recommendations.new(entry[2]).call
        end
        hosts = documents.map { |entry| entry[2]["device"]["host"] }
        names = documents.map { |entry| CLI::Report.device_basename(entry[2].fetch("device")) }
        raise ArgumentError, "设备身份或输出名称重复" unless hosts.uniq == hosts && names.uniq == names
        policy = options[:fabric_policy] && YAML.safe_load(CtxCli::Input.read(path: options[:fabric_policy]), aliases: false)
        Vxlan::Fabric::Scope.new(policy) if policy
        policy
      end

      # 公共入口完成预检后才调用发布；领域报告格式保持独立。
      def publish(documents, options, batch:, context:)
        report = CLI::Report.new(options[:output] || File.join(batch, "reviews"), scripts: options[:scripts] == true)
        report.build_review(documents, policy: context)
        "建议已生成：#{report.directory}/summary.txt；#{documents.size} 台；未执行设备变更。"
      end

      private

      # 先校验公共证据外壳，再验证领域记录。
      def validate(document)
        CtxRunner::Evidence.validate(document) { |record, dimension| validate_record(record, dimension) }
      end

      # 在输出目录创建前验证所有会参与建议生成的嵌套字段。
      def validate_record(record, dimension)
        return unless dimension == "configuration"
        CtxRunner::Evidence.array(record.fetch("review_findings", []))
        nve = record.fetch("nve", {})
        raise ArgumentError, "NVE/VLAN 结构错误" unless nve.is_a?(Hash) && record.fetch("vlan_vnis", {}).is_a?(Hash)
        CtxRunner::Evidence.map(nve.fetch("members", {}))
        CtxRunner::Evidence.map(record.fetch("vrfs", {}))
        CtxRunner::Evidence.map(record.fetch("evpn", {})).each_value { |entry| CtxRunner::Evidence.array(entry.fetch("route_targets", [])) }
        CtxRunner::Evidence.map(record.fetch("interfaces", {})).each_value do |interface|
          addresses, bindings = interface.fetch("addresses", []), interface.fetch("acl_bindings", {})
          unless addresses.is_a?(Array) && addresses.all? { |address| address.is_a?(String) && address.include?("/") } && bindings.is_a?(Hash) && bindings.all? { |direction, name| %w[in out].include?(direction) && name.is_a?(String) }
            raise ArgumentError, "接口结构错误"
          end
          addresses.each { |address| IPAddr.new(address) }
        end
        acls = record.fetch("acls", {})
        raise ArgumentError, "ACL 结构错误" unless acls.is_a?(Hash)
        acls.each_value do |entries|
          CtxRunner::Evidence.array(entries).each do |entry|
            unless entry["sequence"].is_a?(Integer) && %w[permit deny remark].include?(entry["action"]) && entry["expression"].is_a?(String)
              raise ArgumentError, "ACL 规则结构错误"
            end
          end
        end
        groups = record.fetch("address_groups", {})
        raise ArgumentError, "地址组结构错误" unless groups.is_a?(Hash)
        groups.each_value do |members|
          unless members.is_a?(Array) && members.all? { |member| member.is_a?(String) && member.include?("/") && IPAddr.new(member).ipv4? }
            raise ArgumentError, "地址组成员错误"
          end
        end
      end
    end
  end
end
