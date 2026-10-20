# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe "NX-OS ACL dependencies" do
  it "retains address group members as normalized sets independently of sequence and duplicate hosts" do
    result = Vxlan::Config.new.parse(<<~CONFIG, complete: true)
      hostname LEAF
      object-group ip address admins
        30 host 192.0.2.1
        10 198.51.100.0/24
        20 host 192.0.2.1
    CONFIG
    expect(result).to be_complete
    expect(result.records.first[:address_groups]).to eq("admins" => [ "192.0.2.1/32", "198.51.100.0/24" ])
  end

  it "does not silently ignore unsupported address group members" do
    result = Vxlan::Config.new.parse("hostname LEAF\nobject-group ip address admins\n  10 group-object other\n", complete: true)
    expect(result).not_to be_complete
  end

  it "rejects duplicate member sequence numbers instead of trusting an ambiguous group" do
    result = Vxlan::Config.new.parse("hostname LEAF\nobject-group ip address admins\n  10 host 192.0.2.1\n  10 host 192.0.2.2\n", complete: true)
    expect(result).not_to be_complete
  end

  it "does not mark conflicting ACL sequence numbers complete" do
    result = Vxlan::Config.new.parse("hostname LEAF\nip access-list protect\n  10 permit ip any any\n  10 deny ip any any\n", complete: true)
    expect(result).not_to be_complete
  end
end
