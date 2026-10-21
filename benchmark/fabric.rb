# frozen_string_literal: true

require "vxlan"
require "json"

# 两台设备引用相同的不同地址组，完整比较 ACL 及依赖；不包含网络与文件 IO。
puts JSON.generate(ruby: RUBY_DESCRIPTION, source: Vxlan::Fabric::Review.instance_method(:call).source_location)
[ 100, 1000, 3000 ].each do |count|
  groups = (1..count).to_h { |index| [ "G#{index}", [ "192.0.2.0/24" ] ] }
  entries = groups.keys.each_with_index.map do |name, index|
    { "sequence" => index + 1, "action" => "permit", "expression" => "ip addrgroup #{name} any" }
  end
  documents = %w[192.0.2.1 192.0.2.2].each_with_index.map do |host, index|
    config = { "review_status" => "complete", "acls" => { "POLICY" => entries }, "address_groups" => groups }
    config = config.merge("address_groups" => groups.transform_values { [ "198.51.100.0/24" ] }) if index == 1
    { "device" => { "host" => host, "name" => host }, "snapshot" => {
      "dimensions" => { "configuration" => { "status" => "complete", "records" => [ config ] } }
    } }
  end
  policy = { "fabrics" => { "test" => { "leaves" => documents.map { |document| document["device"]["host"] } } } }
  samples = 3.times.map do
    GC.start
    allocated = GC.stat(:total_allocated_objects)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = Vxlan::Fabric::Review.new(documents, policy).call
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    objects = GC.stat(:total_allocated_objects) - allocated
    findings = result[:findings].select { |finding| finding[:code] == "fabric_address_group" }
    raise "Lost group findings" unless findings.size == count && result[:findings].size == count + 1
    raise "Changed evidence order" unless findings.all? { |finding| finding[:evidence].map { |row| row[:host] } == %w[192.0.2.1 192.0.2.2] }
    raise "Unexpected changes" unless result[:device_items].empty?

    { milliseconds: (elapsed * 1000).round(3), allocations: objects }
  end
  puts JSON.generate(groups: count, samples: samples)
end
