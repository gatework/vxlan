# frozen_string_literal: true

require_relative "spec_helper"
require "vxlan/acl_policy"

RSpec.describe Vxlan::AclPolicy do
  let(:entries) do
    [ { "sequence" => 10, "action" => "deny", "expression" => "ip addrgroup admins any" },
      { "sequence" => 20, "action" => "permit", "expression" => "ip any any" } ]
  end
  let(:config) { { "address_groups" => { "admins" => [ "192.0.2.0/24" ] } } }

  it "compares forwarding order and resolved members independently of numbering and remarks" do
    policy = described_class.resolve(config, entries)
    renumbered = entries.each_with_index.map { |entry, index| entry.merge("sequence" => (index + 1) * 100) }
    renumbered << { "sequence" => 1, "action" => "remark", "expression" => "operator note" }
    expect(described_class.resolve(config, renumbered)).to eq(policy)
    reversed = entries.reverse.each_with_index.map { |entry, index| entry.merge("sequence" => (index + 1) * 100) }
    expect(described_class.resolve(config, reversed)).not_to eq(policy)
    expect(described_class.resolve({ "address_groups" => { "admins" => [ "198.51.100.0/24" ] } }, entries)).not_to eq(policy)
  end

  it "preserves unknown evidence separately from an explicitly empty policy" do
    expect(described_class.resolve(config, nil)).to be_nil
    expect(described_class.resolve({}, entries)).to be_nil
    expect(described_class.resolve({ "address_groups" => { "admins" => [] } }, entries)).to be_nil
    expect(described_class.resolve({}, entries.map { |entry| entry.merge("expression" => "tcp any any portgroup web") })).to be_nil
    expect(described_class.resolve({}, []).to_h).to eq("rules" => [], "address_groups" => {})
  end

  it "keeps a time range reference unknown until its dependency is modeled" do
    timed = [ { "sequence" => 10, "action" => "permit", "expression" => "ip any any time-range WINDOW" } ]
    expect(described_class.resolve({}, timed)).to be_nil
  end

  it "owns an immutable snapshot without freezing or retaining caller data" do
    policy = described_class.resolve(config, entries)
    entries.first["expression"] = "ip any any"
    config["address_groups"]["admins"] << "198.51.100.0/24"
    expect(policy.to_h).to eq("rules" => [
      { "action" => "deny", "expression" => "ip addrgroup admins any" }, { "action" => "permit", "expression" => "ip any any" }
    ], "address_groups" => { "admins" => [ "192.0.2.0/24" ] })
    expect { policy.rules.first["expression"].replace("ip any any") }.to raise_error(FrozenError)
    expect { policy.address_groups["admins"] << "203.0.113.0/24" }.to raise_error(FrozenError)
  end

  it "does not assign a policy identity to ambiguous or invalid rule sequence numbers" do
    [ 0, 4_294_967_296, 10 ].each do |sequence|
      invalid = [ entries.first, entries.last.merge("sequence" => sequence) ]
      expect(described_class.resolve(config, invalid)).to be_nil
    end
  end
end
