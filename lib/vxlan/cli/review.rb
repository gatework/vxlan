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
        command = CtxCli::Command.new(banner: "Usage: vxlan review --batch DIR [--output DIR] (generate recommendations offline without executing configuration)", out: @out) do |p, options|
          p.on("--fabric-policy FILE", "Explicit Fabric/Leaf/Border/Spine inventory YAML") { |value| options[:fabric_policy] = value }
          p.on("--batch DIR", "Collected batch containing evidence/*.json") { |value| options[:batch] = value }
          p.on("--[no-]scripts", "Optionally export configuration suggestions; diagnostics only by default") { |value| options[:scripts] = value }
          p.on("--output DIR", "Private output root; defaults to reviews inside the batch") { |value| options[:output] = value }
          p.on("-h", "--help", "Show help") { options[:help] = true }
        end
        CtxCli::Review.new(command: command, directory: "evidence", adapter: self, out: @out, error: @error).run(argv)
      end

      # 领域结构、建议和身份冲突必须在创建输出目录前全部校验。
      def prepare(documents, options)
        documents.each do |entry|
          validate(entry[2])
          entry << Recommendations.new(entry[2]).call
        end
        hosts = documents.map { |entry| entry[2]["target"]["host"] }
        names = documents.map { |entry| CLI::Report.target_basename(entry[2].fetch("target")) }
        raise ArgumentError, "Duplicate device identity or output name" unless hosts.uniq == hosts && names.uniq == names
        policy = options[:fabric_policy] && YAML.safe_load(CtxCli::Input.read(path: options[:fabric_policy]), aliases: false)
        Vxlan::Fabric::Scope.new(policy) if policy
        policy
      end

      # 公共入口完成预检后才调用发布；领域报告格式保持独立。
      def publish(documents, options, batch:, context:)
        report = CLI::Report.new(options[:output] || File.join(batch, "reviews"), scripts: options[:scripts] == true)
        report.build_review(documents, policy: context)
        "Recommendations generated: #{report.directory}/summary.txt; #{documents.size} devices; no device changes executed."
      end

      private

      # 先校验公共证据外壳，再验证领域记录。
      def validate(document)
        CtxRunner::Evidence.validate(document, names: CiscoNxos::Profile::DECLARATIONS.by_dimension.keys) { |record, dimension| validate_record(record, dimension) }
      end

      # 在输出目录创建前验证所有会参与建议生成的嵌套字段。
      def validate_record(record, dimension)
        return unless dimension == "configuration"
        CtxRunner::Evidence.array(record.fetch("review_findings", []))
        nve = record.fetch("nve", {})
        raise ArgumentError, "Invalid NVE/VLAN structure" unless nve.is_a?(Hash) && record.fetch("vlan_vnis", {}).is_a?(Hash)
        CtxRunner::Evidence.map(nve.fetch("members", {}))
        CtxRunner::Evidence.map(record.fetch("vrfs", {}))
        CtxRunner::Evidence.map(record.fetch("evpn", {})).each_value { |entry| CtxRunner::Evidence.array(entry.fetch("route_targets", [])) }
        CtxRunner::Evidence.map(record.fetch("interfaces", {})).each_value do |interface|
          addresses, bindings = interface.fetch("addresses", []), interface.fetch("acl_bindings", {})
          unless addresses.is_a?(Array) && addresses.all? { |address| address.is_a?(String) && address.include?("/") } && bindings.is_a?(Hash) && bindings.all? { |direction, name| %w[in out].include?(direction) && name.is_a?(String) }
            raise ArgumentError, "Invalid interface structure"
          end
          addresses.each { |address| IPAddr.new(address) }
        end
        acls = record.fetch("acls", {})
        raise ArgumentError, "Invalid ACL structure" unless acls.is_a?(Hash)
        acls.each_value do |entries|
          CtxRunner::Evidence.array(entries).each do |entry|
            unless entry["sequence"].is_a?(Integer) && %w[permit deny remark].include?(entry["action"]) && entry["expression"].is_a?(String)
              raise ArgumentError, "Invalid ACL rule structure"
            end
          end
        end
        groups = record.fetch("address_groups", {})
        raise ArgumentError, "Invalid address group structure" unless groups.is_a?(Hash)
        groups.each_value do |members|
          unless members.is_a?(Array) && members.all? { |member| member.is_a?(String) && member.include?("/") && IPAddr.new(member).ipv4? }
            raise ArgumentError, "Invalid address group members"
          end
        end
      end
    end
  end
end
