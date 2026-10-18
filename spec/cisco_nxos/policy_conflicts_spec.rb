# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe "NX-OS policy sequence conflicts" do
  let(:parser) { Vxlan::CiscoNxos::Parsers::ShowRunningConfig.new }

  it "excludes every declaration of a repeated sequence while retaining independent entries" do
    body = <<~CONFIG
      hostname LEAF
      ip prefix-list LIST seq 10 permit 192.0.2.0/24
      ip prefix-list LIST seq 20 permit 198.51.100.0/24
      ip prefix-list LIST seq 10 deny 203.0.113.0/24
      ip prefix-list LIST seq 10 permit 192.0.2.0/24
      route-map POLICY permit 10
        match ip address prefix-list AMBIGUOUS
      route-map POLICY permit 20
        match ip address prefix-list SAFE
      route-map POLICY deny 10
        match ip address prefix-list OTHER
      route-map POLICY permit 10
        match ip address prefix-list AMBIGUOUS
    CONFIG
    result = parser.parse(body, complete: true)
    facts = result.records.first

    expect(result.status).to eq(:partial)
    expect(facts[:prefix_lists]["LIST"].map { |entry| entry[:sequence] }).to eq([ 20 ])
    expect(facts[:route_maps]["POLICY"].map { |entry| entry[:sequence] }).to eq([ 20 ])
    expect(Vxlan::PrefixListReferences.new(facts).call.keys).to eq([ "SAFE" ])
    [ [ :prefix_lists, "LIST" ], [ :route_maps, "POLICY" ] ].each do |path|
      captures = parser.cursor.captures_for(path + [ 0 ])
      expect(captures.size).to eq(1)
      expect(captures.first.data).to eq(facts.dig(*path).first)
      expect(captures.first).to be_complete
    end
    expect(parser.cursor.state(1)).to eq(:invalid)
    expect(parser.cursor.state(5)).to eq(:invalid)
  end

  it "keeps malformed sequence declarations conflicted in either order and resets per parse" do
    valid = "ip prefix-list LIST seq 10 permit 192.0.2.0/24\n"
    invalid = "ip prefix-list LIST seq 10 permit invalid\n"
    [ valid + invalid, invalid + valid, valid + invalid + valid ].each do |body|
      result = parser.parse("hostname LEAF\n#{body}", complete: true)
      expect(result.status).to eq(:partial)
      expect(result.records.first[:prefix_lists]["LIST"]).to be_empty
    end
    expect(parser.parse("hostname LEAF\n#{valid}", complete: true)).to be_complete
  end

  it "isolates equal sequence numbers by family and policy name" do
    result = parser.parse(<<~CONFIG, complete: true)
      hostname LEAF
      ip prefix-list LIST seq 10 permit 192.0.2.0/24
      ipv6 prefix-list LIST seq 10 permit 2001:db8::/32
      ipv6 prefix-list OTHER seq 10 permit 2001:db8:1::/48
      ipv6 prefix-list LIST seq 10 deny 2001:db8:2::/48
    CONFIG

    expect(result.status).to eq(:partial)
    facts = result.records.first
    expect(facts[:ipv6_prefix_lists]["LIST"]).to be_empty
    expect(facts[:prefix_lists]["LIST"].size).to eq(1)
    expect(facts[:ipv6_prefix_lists]["OTHER"].size).to eq(1)
  end

  it "excludes an invalid route-map entry before a later duplicate can restore it" do
    [ "route-map POLICY permit 10\n  invalid-policy-command\n", "route-map POLICY permit 10\n  match ip address prefix-list SAFE\n" ].permutation.each do |commands|
      result = parser.parse("hostname LEAF\n#{commands.join}", complete: true)

      expect(result.status).to eq(:partial)
      expect(result.records.first[:route_maps]["POLICY"]).to be_empty
      expect(Vxlan::PrefixListReferences.new(result.records.first).call).to be_empty
    end
  end
end
