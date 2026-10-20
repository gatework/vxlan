# frozen_string_literal: true

require_relative "spec_helper"
require "open3"
require "tmpdir"
require "json"
require "rbconfig"

RSpec.describe "Saved-evidence replay framing" do
  [ [ "LAB#", true ], [ "private transport diagnostic #", false ], [ "LAB#\x00", false ] ].each do |prompt, valid|
    it "#{valid ? 'accepts' : 'rejects'} the final line #{prompt.inspect} without discarding diagnostic data" do
      Dir.mktmpdir do |directory|
        command = "show bgp l2vpn evpn summary"
        body = File.binread(File.join(__dir__, "fixtures/evidence/bgp_summary.txt"))
        File.binwrite(File.join(directory, command.tr(" ", "_") + ".txt"), "#{command}\n#{body}#{prompt}\n")
        output, error, status = Open3.capture3({ "EVIDENCE_LIBRARY" => nil }, RbConfig.ruby,
          File.expand_path("../script/replay_evidence.rb", __dir__), directory, "bgp_neighbors")
        expect(status.success?).to eq(valid)
        if valid
          expect(JSON.parse(output).fetch("results").first).to include("status" => "complete")
        else
          expect(output).to eq("")
          expect(error).to include("Unverified command framing")
          expect(error).not_to include("private transport diagnostic", directory)
        end
      end
    end
  end
end
