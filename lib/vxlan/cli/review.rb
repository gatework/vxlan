# frozen_string_literal: true

require "optparse"
require "json"
require "digest"
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
        options = {}
        parser = OptionParser.new do |p|
          p.banner = "用法：vxlan review --batch DIR [--output DIR]（离线生成建议，不执行配置）"
          p.on("--fabric-policy FILE", "显式 Fabric/Leaf/Border/Spine 清单 YAML") { |value| options[:fabric_policy] = value }
          p.on("--batch DIR", "已采集批次，含 evidence/*.json") { |value| options[:batch] = value }
          p.on("--[no-]scripts", "可选导出配置建议，默认仅诊断") { |value| options[:scripts] = value }
          p.on("--output DIR", "私有输出根目录，默认批次内 reviews") { |value| options[:output] = value }
          p.on("-h", "--help", "查看帮助") { options[:help] = true }
        end
        rest = parser.parse(argv.dup)
        return @out.puts(parser) || 0 if options[:help]
        raise ArgumentError, "需要批次目录" unless rest.empty? && options[:batch]
        batch = File.expand_path(options[:batch])
        paths = Dir[File.join(batch, "evidence", "*.json")].sort
        raise ArgumentError, "无设备报告" if paths.empty?
        # 先校验所有输入，损坏文件不会留下看似完成的部分建议批次。
        documents = paths.map do |path|
          body = File.read(path)
          document = JSON.parse(body)
          validate(document)
          [ path, body, document, Recommendations.new(document).call ]
        end
        hosts = documents.map { |entry| entry[2]["device"]["host"] }
        names = documents.map { |entry| CLI::Report.device_basename(entry[2].fetch("device")) }
        raise ArgumentError, "设备身份或输出名称重复" unless hosts.uniq == hosts && names.uniq == names
        policy = options[:fabric_policy] && YAML.safe_load(File.read(options[:fabric_policy]), aliases: false)
        Vxlan::Fabric::Scope.new(policy) if policy
        report = CLI::Report.new(options[:output] || File.join(batch, "reviews"), scripts: options[:scripts] == true)
        report.build_review(documents, policy: policy)
        @out.puts "建议已生成：#{report.directory}/summary.txt；#{documents.size} 台；未执行设备变更。"
        0
      rescue Psych::Exception, OptionParser::ParseError, ArgumentError, TypeError, KeyError, JSON::ParserError, SystemCallError, IOError => error
        @error.puts "建议生成失败（#{error.class.name}）；请检查输入结构、目录权限和 --help；未执行设备变更。"
        2
      end

      private

      # 仅接受宿主保存的设备快照边界；缺少快照的失败采集仍可生成补采任务。
      def validate(document)
        raise ArgumentError, "无设备身份" unless document.is_a?(Hash) && document["device"].is_a?(Hash) && %w[name host].all? { |key| document["device"][key].is_a?(String) }
        host = document["device"]["host"]
        raise ArgumentError, "目标地址须为规范主机地址" unless !host.include?("/") && IPAddr.new(host).to_s == host
        snapshot = document["snapshot"]
        raise ArgumentError, "无快照字段" unless document.key?("snapshot")
        return if snapshot.nil?
        raise ArgumentError, "快照结构错误" unless snapshot.is_a?(Hash) && snapshot["dimensions"].is_a?(Hash)
        if snapshot.key?("target") && (!snapshot["target"].is_a?(Hash) || snapshot["target"]["host"] != host)
          raise ArgumentError, "设备身份与采集目标不一致"
        end
        snapshot["dimensions"].each do |dimension, observation|
          unless observation.is_a?(Hash) && %w[complete partial failed unsupported not_requested].include?(observation["status"]) && observation["records"].is_a?(Array) && observation["records"].all? { |record| record.is_a?(Hash) }
            raise ArgumentError, "观测结构错误"
          end
          array_of_hashes(observation.fetch("issues", []))
          observation["records"].each { |record| validate_record(record, dimension) }
        end
      end

      # 校验规则读取的容器类型，错误消息不包含配置正文。
      def array_of_hashes(value)
        raise ArgumentError, "列表结构错误" unless value.is_a?(Array) && value.all? { |entry| entry.is_a?(Hash) }
        value
      end

      # 映射值必须仍是记录，不能将损坏结构解释成空事实。
      def hash_of_hashes(value)
        raise ArgumentError, "映射结构错误" unless value.is_a?(Hash) && value.values.all? { |entry| entry.is_a?(Hash) }
        value
      end

      # 在输出目录创建前验证所有会参与建议生成的嵌套字段。
      def validate_record(record, dimension)
        return unless dimension == "configuration"
        array_of_hashes(record.fetch("review_findings", []))
        nve = record.fetch("nve", {})
        raise ArgumentError, "NVE/VLAN 结构错误" unless nve.is_a?(Hash) && record.fetch("vlan_vnis", {}).is_a?(Hash)
        hash_of_hashes(nve.fetch("members", {}))
        hash_of_hashes(record.fetch("vrfs", {}))
        hash_of_hashes(record.fetch("evpn", {})).each_value { |entry| array_of_hashes(entry.fetch("route_targets", [])) }
        hash_of_hashes(record.fetch("interfaces", {})).each_value do |interface|
          addresses, bindings = interface.fetch("addresses", []), interface.fetch("acl_bindings", {})
          unless addresses.is_a?(Array) && addresses.all? { |address| address.is_a?(String) && address.include?("/") } && bindings.is_a?(Hash) && bindings.all? { |direction, name| %w[in out].include?(direction) && name.is_a?(String) }
            raise ArgumentError, "接口结构错误"
          end
          addresses.each { |address| IPAddr.new(address) }
        end
        acls = record.fetch("acls", {})
        raise ArgumentError, "ACL 结构错误" unless acls.is_a?(Hash)
        acls.each_value do |entries|
          array_of_hashes(entries).each do |entry|
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
