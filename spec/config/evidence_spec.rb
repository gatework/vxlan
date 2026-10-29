# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Vxlan::Config::Evidence do
  it "returns only one reviewed complete record from a complete observation" do
    record = { "review_status" => "complete" }
    document = { "snapshot" => { "observations" => { "configuration" => { "status" => "complete", "records" => [ record ] } } } }
    expect(described_class.complete_record(document)).to equal(record)

    observation = document["snapshot"]["observations"]["configuration"]
    [ [], [ record, record ], [ { "review_status" => "partial" } ], [ {} ], [ nil ] ].each do |records|
      observation["records"] = records
      expect(described_class.complete_record(document)).to be_nil
    end
    observation["records"] = [ record ]
    %w[partial failed unsupported not_requested].each do |status|
      observation["status"] = status
      expect(described_class.complete_record(document)).to be_nil
    end
    expect(described_class.complete_record("snapshot" => nil)).to be_nil
    expect(described_class.complete_record(nil)).to be_nil
  end
end
