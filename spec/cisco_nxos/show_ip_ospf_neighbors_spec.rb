# frozen_string_literal: true

require_relative "../spec_helper"
require "vxlan/cisco_nxos/parsers/show_ip_ospf_neighbors"

RSpec.describe Vxlan::CiscoNxos::Parsers::ShowIpOspfNeighbors do
  let(:output) { File.read(File.expand_path("../fixtures/ctx_parser/show_ip_ospf_neighbors.txt", __dir__)) }

  it "accepts only CLI text and returns facts independently of collection metadata" do
    result = described_class.parse(output, complete: true)

    expect(result).to be_a(CtxParser::Result)
    expect(result).to be_complete
    expect(result.to_h.keys).to contain_exactly(:status, :records, :issues, :covered_scopes)
    expect(result.records).to eq([ { router_id: "192.0.2.2", priority: 1, state: :full, neighbor_role: :unknown, uptime: "1d",
      neighbor_address: "192.0.2.3", interface: "Eth1/1", process_id: "UNDERLAY", vrf: "default" } ])
    expect(described_class.parse(output).issues).to include(code: :output_incomplete)
  end

  it "keeps processes and VRFs separate and preserves an incomplete scope" do
    second = output.sub("VRF default", "VRF BLUE")
    result = described_class.parse(output + second, complete: true)
    expect(result).to be_complete
    expect(result.records.map { |row| row[:vrf] }).to eq(%w[default BLUE])

    truncated = second.lines[0..2].join
    result = described_class.parse(output + truncated, complete: true)
    expect(result.status).to eq(:partial)
    expect(result.records.size).to eq(1)
    expect(result.issues).to include(code: :count_mismatch, expected: 1, observed: 0)
  end

  it "requires explicit zero-neighbor evidence before returning an empty complete result" do
    header_only = output.lines[0, 1].join + output.lines[2, 1].join
    expect(described_class.parse(header_only, complete: true).status).to eq(:partial)

    empty = described_class.parse("Total number of neighbors: 0\n", complete: true)
    expect(empty).to be_complete
    expect(empty.records).to be_empty
    expect(described_class.parse("No peers found\n", complete: true).status).to eq(:partial)
  end

  it "reports the source line of unknown output without including its content" do
    result = described_class.parse(output + "sensitive unknown output\n", complete: true)
    expect(result.issues).to eq([ { code: :unparsed_row, line: 5 } ])
    expect(result.inspect).not_to include("192.0.2.2", "sensitive")
  end

  it "validates the input contract without silently coercing objects or completeness" do
    [ nil, [], { output: output } ].each do |input|
      expect { described_class.parse(input) }.to raise_error(ArgumentError, "Parser input must be text")
    end
    expect { described_class.parse(output, complete: "true") }.to raise_error(ArgumentError, "Completeness must be boolean")
  end

  it "handles binary output without mutating the caller's text and preserves invalid encoding" do
    raw = output.gsub("\n", "\r\n").b.freeze
    expect(described_class.parse(raw, complete: true)).to be_complete
    expect(raw.encoding).to eq(Encoding::BINARY)
    expect(raw).to include("\r\n")

    result = described_class.parse(raw + "\xFF".b, complete: true)
    expect(result.to_h).to eq(covered_scopes: [], status: :partial, records: [], issues: [ { code: :invalid_encoding } ])
  end

  it "does not reuse rows or diagnostics across independent parses" do
    parser = described_class.new
    first = parser.parse(output + "unknown\n", complete: true)
    unsupported = parser.parse("% Invalid command at '^' marker.\n", complete: true)
    last = parser.parse(output, complete: true)

    expect(unsupported.to_h).to eq(covered_scopes: [], status: :unsupported, records: [], issues: [ { code: :command_unsupported } ])
    expect(last).to be_complete
    expect(first.status).to eq(:partial)
    expect(first.issues).to eq([ { code: :unparsed_row, line: 5 } ])
    expect(last.records).to eq(first.records)
  end
end
