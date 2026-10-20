# frozen_string_literal: true

require "json"
require "digest"

# 仅回放本机已保存回显；输出摘要与摘要哈希，不输出正文、设备名或原始文件路径。
library = File.realpath(ENV.fetch("EVIDENCE_LIBRARY", File.expand_path("../lib", __dir__)))
$LOAD_PATH.unshift(library)
require "vxlan"
abort "Unexpected library source" unless $LOADED_FEATURES.include?(File.join(library, "vxlan.rb"))

root = ARGV.shift
abort "Usage: ruby script/replay_evidence.rb CAPTURE_ROOT DIMENSION [...]" unless root && !ARGV.empty?
profile = Vxlan::ParserRegistry.fetch(:cisco_nxos)
names = ARGV.map(&:to_sym)
abort "Unsupported or duplicate dimensions" unless names.uniq == names && (names - profile.commands.keys).empty?
results = names.flat_map do |name|
  command = profile.command(name)
  filename = command.tr(" ", "_") + ".txt"
  Dir[File.join(root, "**", filename)].sort.map do |path|
    raw = File.binread(path)
    lines = raw.lines("\n")
    # 来源保存的是完整回执；仅精确匹配回显命令和单行提示符后才提取正文。
    first = lines.first&.delete_suffix("\n")&.delete_suffix("\r")
    last = lines.last&.delete_suffix("\n")&.delete_suffix("\r")
    framed = first == command && /\A(?:[^\s#<>\x00-\x1f\x7f]+#|<[^\s#<>\x00-\x1f\x7f]+>)\z/.match?(last.to_s)
    abort "Unverified command framing: #{Digest::SHA256.hexdigest(raw)}" unless framed
    body = lines[1...-1].join
    observation = Vxlan::RuntimeParser.new.parse(name, body, complete: true)
    { raw_sha256: Digest::SHA256.hexdigest(raw), input_sha256: Digest::SHA256.hexdigest(body),
      command: command, dimension: name, framing: "exact_command_and_prompt_removed", bytes: body.bytesize,
      status: observation.status, records: observation.records.size,
      issues: observation.issues.map { |issue| issue[:code] },
      result_sha256: Digest::SHA256.hexdigest(JSON.generate(observation.to_h)) }
  end
end
abort "No matching captures" if results.empty?
puts JSON.pretty_generate(runtime: RUBY_VERSION, library_root: library,
  gems: Gem.loaded_specs.slice("ctx_parser", "ctx_driver").transform_values { |spec| spec.version.to_s }, results: results)
