# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "Immutable facts and evidence" do
  [ Vxlan::Observation ].each do |type|
    context type.name do
      let(:attributes) { type == CtxParser::Result ? {} : { name: :configuration } }

      it "detaches nested facts and diagnostics without freezing caller data" do
        records = [ { name: +"leaf", nested: { members: [ +"Ethernet1/1" ] } } ]
        issues = [ { code: :partial_source, fields: [ +"name" ] } ]
        value = type.new(**attributes, status: :partial, records: records, issues: issues)
        records.first[:name].replace("caller changed")
        records.first[:nested][:members].clear
        issues.first[:fields].clear

        expect(value.records).to eq([ { name: "leaf", nested: { members: [ "Ethernet1/1" ] } } ])
        expect(value.issues).to eq([ { code: :partial_source, fields: [ "name" ] } ])
        expect { value.records.first[:nested][:members].clear }.to raise_error(FrozenError)
        expect { value.issues.first[:fields].first.replace("changed") }.to raise_error(FrozenError)
      end

      it "keeps replacement facts independent while preserving Data value semantics" do
        original = type.new(**attributes, status: :complete, records: [ { name: "leaf" } ])
        input = [ { name: +"replacement" } ]
        replaced = original.with(status: :partial, records: input)
        input.first[:name].clear
        expect(replaced.records).to eq([ { name: "replacement" } ])
        expect(original.records).to eq([ { name: "leaf" } ])
        expect(replaced.to_h[:status]).to eq(:partial)
      end
    end
  end

  [ Vxlan ].each do |domain|
    it "detaches #{domain} evidence and timestamps from caller state" do
      evidence = [ { command: +"show test", sha256: +"digest" } ]
      time = Time.now
      expected_time = time.dup
      value = domain::Observation.new(name: :configuration, status: :complete,
        evidence: evidence, started_at: time, completed_at: time)
      evidence.first[:command].clear
      time.localtime("+09:00")

      expect(value.evidence.first[:command]).to eq("show test")
      expect(value.completed_at.utc_offset).to eq(expected_time.utc_offset)
      expect { value.evidence.clear }.to raise_error(FrozenError)
      expect { value.completed_at.localtime("+07:00") }.to raise_error(FrozenError)
    end

    it "protects #{domain} snapshot identity and dimension coverage from caller mutation" do
      dimensions = { configuration: domain::Observation.new(name: :configuration, status: :complete) }
      target = { host: +"192.0.2.1", attributes: { serial: +"leaf-1" } }
      attributes = { fabric_key: +"LAB" }
      value = domain::Snapshot.new(target: target, dimensions: dimensions, observed_at: Time.now, **attributes)
      dimensions.clear
      target[:host].replace("192.0.2.2")
      attributes[:fabric_key]&.clear

      expect(value).to be_complete
      expect(value.target[:host]).to eq("192.0.2.1")
      expect(value.fabric_key).to eq("LAB")
      expect { value.dimensions.clear }.to raise_error(FrozenError)
      expect { value.target[:attributes][:serial].clear }.to raise_error(FrozenError)
      expect(value.observed_at).to be_frozen
    end
  end
end
