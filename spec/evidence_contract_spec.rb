# frozen_string_literal: true

require_relative "spec_helper"
require "json"
require "digest"

RSpec.describe "VXLAN evidence contracts" do
  let(:root) { File.join(__dir__, "fixtures/evidence") }
  let(:body) { File.binread(File.join(root, "bgp_summary.txt")) }

  it "allows unlisted route types but includes Type-12 in the upper bound when present" do
    parser = Vxlan::RuntimeParser.new
    fewer = body.sub("3249 1864 693 0 692", "3249 1864 693 0 691")
    expect(parser.parse(:bgp_neighbors, fewer, complete: true)).to be_complete
    with_type12 = body.sub("Type-5\n", "Type-5 Type-12\n").lines("\n").map do |line|
      /\A192\.0\.2\.[23] I /.match?(line) ? line.chomp + " 1\n" : line
    end.join
    result = parser.parse(:bgp_neighbors, with_type12, complete: true)
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :inconsistent_prefix_statistics))
  end

  it "isolates equivalent dynamic prefix conflicts within their own VRF" do
    result = Vxlan::Config.new.parse("hostname LEAF\nrouter bgp 65000\n" \
      "  neighbor 2001:0db8::/64\n    remote-as 65001\n" \
      "  neighbor 2001:db8:0:0::/64\n    remote-as 65002\n" \
      "  vrf BLUE\n    neighbor 2001:db8::/64\n      remote-as 65003\n", complete: true)
    expect(result.status).to eq(:partial)
    expect(result.records.first.dig(:bgp, :neighbors)).to be_empty
    expect(result.records.first.dig(:bgp, :vrfs, "BLUE", :neighbors).keys).to eq([ "2001:db8::/64" ])
  end

  it "replays a saved-command specimen against independently annotated literal facts" do
    JSON.parse(File.read(File.join(root, "manifest.json"))).fetch("cases").each do |entry|
      input = File.binread(File.join(root, entry.fetch("file")))
      expect(Digest::SHA256.hexdigest(input)).to eq(entry.fetch("sha256"))
      actual = Vxlan::RuntimeParser.new.parse(:bgp_neighbors, input, complete: true)
      expect(JSON.parse(JSON.generate(actual.to_h.slice(:status, :records, :issues)))).to eq(entry.fetch("expected"))
    end
  end

  it "does not accept route-type counts exceeding the independently reported total" do
    result = Vxlan::RuntimeParser.new.parse(:bgp_neighbors, body.sub("3249 1864 693 0 692", "3249 4000 693 0 692"), complete: true)
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :inconsistent_prefix_statistics))
    expect(result.records.first).not_to have_key(:prefixes_by_type)
    expect(result.records.last[:prefixes_by_type]).to eq(type2: 1864, type3: 693, type4: 0, type5: 692)
  end

  it "excludes equivalent configured IPv6 identities while retaining valid siblings and original keys" do
    result = Vxlan::Config.new.parse("hostname LEAF\nrouter bgp 65000\n" \
      "  neighbor 2001:0db8:0:0::1\n    remote-as 65001\n" \
      "  neighbor 2001:db8::1\n    remote-as 65002\n" \
      "  neighbor 2001:db8:0:0::1\n    remote-as 65003\n" \
      "  neighbor 2001:0DB8::2\n    remote-as 65004\n", complete: true)
    expect(result.status).to eq(:partial)
    expect(result.records.first.dig(:bgp, :neighbors).keys).to eq([ "2001:0DB8::2" ])
    expect(result.issues).to include(include(code: :duplicate_identity))
  end

  it "cannot gain completeness by removing an advertised statistics row or the transport assertion" do
    parser = Vxlan::RuntimeParser.new
    expect(parser.parse(:bgp_neighbors, body, complete: false).status).to eq(:partial)
    missing = body.lines("\n").reject { |line| line.start_with?("192.0.2.2 I ") }.join
    expect(parser.parse(:bgp_neighbors, missing, complete: true).status).to eq(:partial)
  end
end
