# frozen_string_literal: true

require_relative "../spec_helper"
require "vxlan/cli"
require "vxlan/cli/report"
require "tmpdir"
require "stringio"
require "digest"

RSpec.describe "Vxlan offline review" do
  it "rejects oversized source documents before creating reports" do
    require "ctx_cli/input"
    stub_const("CtxCli::Input::MAX_BYTES", 32)
    Dir.mktmpdir do |root|
      Dir.mkdir(File.join(root, "evidence"))
      File.write(File.join(root, "evidence", "large.json"), JSON.generate(schema_version: 3, kind: "collection", device: { name: "AC", host: "192.0.2.1" }, snapshot: nil))
      error = StringIO.new
      expect(Vxlan::CLI.run([ "review", "--batch", root ], out: StringIO.new, error: error)).to eq(2)
      expect(File.exist?(File.join(root, "reviews"))).to be(false)
      expect(error.string).not_to include("192.0.2.1")
    end
  end

  it "displays unknown ACL dependencies explicitly instead of fingerprinting an unverified policy" do
    Dir.mktmpdir do |root|
      report = Vxlan::CLI::Report.new(root)
      rows = %w[deny permit].map do |action|
        rules = [ { "action" => action, "expression" => "ip addrgroup UNKNOWN any" } ]
        { host: "192.0.2.1", entries: rules, semantics: rules, policy: nil }
      end
      audit = { findings: [ { fabric: "test", code: "fabric_acl_content", title: "ACL diff", evidence: rows } ] }
      text = report.fabric_text(audit, [])
      expect(text).to include("Dependencies unverified", "deny ip addrgroup UNKNOWN any", "permit ip addrgroup UNKNOWN any")
      expect(text).not_to include(CtxRunner::Fingerprint.call(nil)[0, 12])
    end
  end

  it "does not fall back to legacy JSON in the user-facing devices directory" do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "devices"))
      File.write(File.join(root, "devices", "old.json"), JSON.generate(schema_version: 3, kind: "collection", device: { name: "leaf", host: "192.0.2.1" }, snapshot: nil))
      expect(Vxlan::CLI.run([ "review", "--batch", root ], out: StringIO.new, error: StringIO.new)).to eq(2)
      expect(Dir[File.join(root, "reviews", "*")]).to be_empty
    end
  end

  it "publishes topology-style text reports and one checksummed batch plan without Markdown" do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "evidence"))
      File.write(File.join(root, "evidence", "leaf.json"), JSON.generate(schema_version: 3, kind: "collection", device: { name: "leaf", host: "192.0.2.1" }, snapshot: nil))
      expect(Vxlan::CLI.run([ "review", "--batch", root ], out: StringIO.new, error: StringIO.new)).to eq(0)
      generated = Dir[File.join(root, "reviews", "*")].fetch(0)
      expect(Dir.children(generated).sort).to eq(%w[devices events.jsonl plan.json plan.json.sha256 summary.json summary.txt])
      expect(Dir[File.join(generated, "**", "*.md")]).to be_empty
      expect(File.read(File.join(generated, "plan.json.sha256")).strip).to eq(Digest::SHA256.file(File.join(generated, "plan.json")).hexdigest)
      plan = JSON.parse(File.read(File.join(generated, "plan.json")))
      expect(plan["changes"]).to eq({})
      expect(plan["audits"].first["items"]).not_to be_empty
      expect(File.read(File.join(generated, "devices", "leaf-192.0.2.1.txt"))).to include("Device: leaf", "no device configuration executed")
    end
  end
  it "keeps devices without findings represented without generating empty scripts" do
    Dir.mktmpdir do |root|
      report = Vxlan::CLI::Report.new(root, scripts: true)
      device = { "name" => "LEAF", "host" => "192.0.2.1" }
      advice = { device: device, items: [], counts: {} }
      entry = report.write_review({ "device" => device }, basename: "leaf", source: "source.json", source_sha256: "a" * 64, advice: advice)
      report.finish_review([ entry ], source_batch: root)
      expect(Dir.children(report.directory).sort).to eq(%w[devices events.jsonl plan.json plan.json.sha256 summary.json summary.txt])
      manifest = JSON.parse(File.read(File.join(report.directory, "summary.json")))
      expect(manifest["reports"].first).to include("report" => "devices/leaf.txt", "source_sha256" => "a" * 64)
      expect(File.read(File.join(report.directory, "summary.txt"))).to include("no rules matched 1 devices")
    end
  end

  it "reviews a common deployed service through the CLI and gates every script artifact" do
    Dir.mktmpdir do |root|
      batch = File.join(root, "source")
      FileUtils.mkdir_p(File.join(batch, "evidence"))
      hosts = %w[192.0.2.1 192.0.2.2]
      hosts.each_with_index do |host, index|
        config = { "review_status" => "complete", "vlan_vnis" => { "8" => 10008 }, "vrfs" => {}, "evpn" => { "10008" => { "type" => "l2" } }, "nve" => { "members" => { "10008" => { "associate_vrf" => false, "replication" => "bgp" } } },
          "interfaces" => { "Vlan8" => { "addresses" => [ "192.0.2.254/24" ], "vrf" => "tenant", "anycast" => true, "acl_bindings" => index.zero? ? { "out" => "protect" } : {} } },
          "acls" => { "protect" => [ { "sequence" => 10, "action" => "permit", "expression" => "ip any any" } ] } }
        document = { schema_version: 3, kind: "collection", device: { host: host, name: "leaf#{index}", platform: "cisco_nxos" }, snapshot: { collection_status: "complete", observed_at: "2026-10-29T00:00:00.000000Z", target: { host: host }, observations: { configuration: { name: "configuration", status: "complete", records: [ config ], issues: [] } } } }
        File.write(File.join(batch, "evidence", "leaf#{index}.json"), JSON.generate(document))
      end
      policy = File.join(root, "fabric.yml")
      File.write(policy, YAML.dump("fabrics" => { "test" => { "leaves" => hosts } }))
      [ false, true ].each do |scripts|
        output = File.join(root, scripts ? "scripts" : "plain")
        args = [ "review", "--batch", batch, "--output", output, "--fabric-policy", policy ]
        args << "--scripts" if scripts
        error = StringIO.new
        expect(Vxlan::CLI.run(args, out: StringIO.new, error: error)).to eq(0), error.string
        batch_plan = JSON.parse(File.read(Dir[File.join(output, "*", "plan.json")].fetch(0)))
        item = batch_plan.fetch("audits").find { |audit| audit["device"]["host"] == hosts.last }.fetch("items").find { |advice| advice["code"] == "fabric_acl_binding" }
        plans = batch_plan.fetch("changes").values
        expect(item["commands"].any?).to eq(scripts)
        expect(item.key?("change")).to eq(scripts)
        expect(plans.size).to eq(scripts ? 1 : 0)
        generated = Dir[File.join(output, "*")].fetch(0)
        expect(Dir[File.join(generated, "scripts", "*.cfg")].any?).to eq(scripts)
        expect(Dir[File.join(generated, "**", "*.md")]).to be_empty
        expect(Dir[File.join(generated, "**", "*.cli")]).to be_empty
        summary = JSON.parse(File.read(File.join(generated, "summary.json")))
        summary["reports"].each do |entry|
          expect(File).to exist(File.join(generated, entry["report"]))
          expect(File).to exist(File.join(generated, entry["script"])) if entry["script"]
          expect(entry["plans"] - batch_plan["changes"].keys).to be_empty
        end
        if scripts
          plan = plans.first
          expect(plan["commands"]).to eq(Vxlan::ChangePlan.build(plan["change"]).commands)
          expect(plan["source_sha256"]).to eq(Digest::SHA256.file(plan["source"]).hexdigest)
          expect(File.read(File.join(generated, "devices", "leaf1-192.0.2.2.txt"))).to include("--item #{batch_plan['changes'].keys.first}")
        end
      end
    end
  end

  it "rejects duplicate device identities before they overwrite a stable report name" do
    Dir.mktmpdir do |root|
      Dir.mkdir(File.join(root, "evidence"))
      document = { schema_version: 3, kind: "collection", device: { name: "leaf", host: "192.0.2.1" }, snapshot: nil }
      %w[a b].each { |name| File.write(File.join(root, "evidence", "#{name}.json"), JSON.generate(document)) }
      expect(Vxlan::CLI.run([ "review", "--batch", root ], out: StringIO.new, error: StringIO.new)).to eq(2)
      expect(Dir[File.join(root, "reviews", "*")]).to be_empty
    end
  end

  it "rejects ambiguous host spellings and a snapshot captured from a different host before writing" do
    [
      { device: { name: "leaf", host: "2001:0db8:0::1" }, snapshot: nil },
      { device: { name: "leaf", host: "192.0.2.1/32" }, snapshot: nil },
      { device: { name: "leaf", host: "192.0.2.1" }, snapshot: { collection_status: "complete", observed_at: "2026-10-29T00:00:00.000000Z", target: { host: "192.0.2.2" }, observations: {} } }
    ].each do |document|
      Dir.mktmpdir do |root|
        Dir.mkdir(File.join(root, "evidence"))
        File.write(File.join(root, "evidence", "leaf.json"), JSON.generate(document))
        expect(Vxlan::CLI.run([ "review", "--batch", root ], out: StringIO.new, error: StringIO.new)).to eq(2)
        expect(Dir[File.join(root, "reviews", "*")]).to be_empty
      end
    end
  end

  it "reviews saved facts without changing the source and binds recommendations to its hash" do
    Dir.mktmpdir do |root|
      batch = File.join(root, "source")
      Dir.mkdir(batch)
      Dir.mkdir(File.join(batch, "evidence"))
      source = File.join(batch, "evidence", "leaf.json")
      body = JSON.generate(schema_version: 3, kind: "collection", device: { name: "LEAF", host: "192.0.2.1", platform: "h3c_wireless" }, snapshot: { collection_status: "partial", observed_at: "2026-10-29T00:00:00.000000Z", target: { host: "192.0.2.1" }, observations: { configuration: { name: "configuration", status: "partial", records: [], issues: [] } } })
      File.write(source, body)
      out, error = StringIO.new, StringIO.new
      status = Vxlan::CLI.run([ "review", "--batch", batch, "--output", File.join(root, "out") ], out: out, error: error)
      expect(status).to eq(0), error.string
      expect(File.read(source)).to eq(body)
      summary = JSON.parse(File.read(Dir[File.join(root, "out", "*", "summary.json")].fetch(0)))
      expect(summary).to include("status" => "complete", "review_only" => true, "devices" => 1)
      review = JSON.parse(File.read(Dir[File.join(root, "out", "*", "plan.json")].fetch(0))).fetch("audits").first
      expect(review).to include("source_sha256" => Digest::SHA256.hexdigest(body))
      expect(review["items"]).to include(include("code" => "evidence_incomplete"))
      Dir[File.join(root, "out", "**", "*")].select { |path| File.file?(path) }.each do |path|
        expect(File.stat(path).mode & 0o777).to eq(0o600)
      end
    end
  end

  it "rejects malformed input without printing its sensitive content or a completed manifest" do
    Dir.mktmpdir do |root|
      Dir.mkdir(File.join(root, "evidence"))
      File.write(File.join(root, "evidence", "broken.json"), "private-password-invalid-json")
      out, error = StringIO.new, StringIO.new
      expect(Vxlan::CLI.run([ "review", "--batch", root, "--output", File.join(root, "out") ], out: out, error: error)).to eq(2)
      expect(error.string).not_to include("private-password")
      expect(Dir[File.join(root, "out", "*", "summary.json")]).to be_empty
    end
  end

  it "automatically includes advice in new collection reports" do
    Dir.mktmpdir do |root|
      report = Vxlan::CLI::Report.new(File.join(root, "out"))
      report.write({ device: { "name" => "LEAF", "host" => "192.0.2.1", "platform" => "h3c_wireless" }, status: :failed, dimensions: {} })
      document = JSON.parse(File.read(Dir[File.join(report.directory, "evidence", "*.json")].fetch(0)))
      expect(document.fetch("recommendations")).to include("review_only" => true)
      expect(Dir[File.join(report.directory, "devices", "*.txt")].size).to eq(1)
    end
  end
  it "rejects malformed nested observations through the normal error channel" do
    Dir.mktmpdir do |root|
      Dir.mkdir(File.join(root, "evidence"))
      File.write(File.join(root, "evidence", "bad.json"), JSON.generate(schema_version: 3, kind: "collection", device: { name: "test", host: "192.0.2.1" }, snapshot: { collection_status: "partial", observed_at: "2026-10-29T00:00:00.000000Z", target: { host: "192.0.2.1" }, observations: { configuration: { name: "configuration", status: "partial", records: [], issues: "private-password" } } }))
      error = StringIO.new
      expect(Vxlan::CLI.run([ "review", "--batch", root ], error: error, out: StringIO.new)).to eq(2)
      expect(error.string).not_to include("private-password")
      expect(Dir[File.join(root, "reviews", "*", "summary.json")]).to be_empty
    end
  end

  it "rejects malformed Fabric inputs before publishing reports" do
    [ { interfaces: { "Vlan8" => "private-value" } }, { interfaces: { "Vlan8" => { addresses: nil } } }, { acls: { protect: [ { sequence: "private-value" } ] } },
      { address_groups: "private-value" }, { address_groups: { admins: [ "private-value" ] } } ].each do |record|
      Dir.mktmpdir do |root|
        Dir.mkdir(File.join(root, "evidence"))
        File.write(File.join(root, "evidence", "bad.json"), JSON.generate(schema_version: 3, kind: "collection", device: { name: "test", host: "192.0.2.1" }, snapshot: { collection_status: "complete", observed_at: "2026-10-29T00:00:00.000000Z", target: { host: "192.0.2.1" }, observations: { configuration: { name: "configuration", status: "complete", records: [ record ] } } }))
        error = StringIO.new
        expect(Vxlan::CLI.run([ "review", "--batch", root ], error: error, out: StringIO.new)).to eq(2)
        expect(error.string).not_to include("private-value")
        expect(Dir[File.join(root, "reviews", "*", "summary.json")]).to be_empty
      end
    end
  end

  it "restores an incomplete review manifest if final directory sync fails after rename" do
    Dir.mktmpdir do |root|
      report = Vxlan::CLI::Report.new(File.join(root, "reports"))
      original = File.method(:rename)
      renamed = 0
      allow(File).to receive(:rename) do |source, target|
        renamed += 1 if target.end_with?("/summary.json")
        original.call(source, target)
      end
      original_open = File.method(:open)
      allow(File).to receive(:open) do |*args, **kwargs, &operation|
        next original_open.call(*args, **kwargs) unless operation
        original_open.call(*args, **kwargs) do |file|
          allow(file).to receive(:fsync).and_raise(Errno::EIO) if renamed == 2 && file.stat.directory?
          operation.call(file)
        end
      end
      expect { report.finish_review([], source_batch: root) }.to raise_error(Vxlan::CLI::Report::Error)
      saved = JSON.parse(File.read(File.join(report.directory, "summary.json")))
      expect(saved["status"]).to eq("incomplete")
    end
  end
  it "exports configuration drafts only when explicitly requested" do
    Dir.mktmpdir do |root|
      document = { "schema_version" => 3, "kind" => "collection", "device" => { "host" => "192.0.2.1", "name" => "test" }, "snapshot" => nil }
      advice = { device: document["device"], items: [ { code: "test", scope: "test", title: "test", status: "candidate", evidence: {}, prerequisites: [], blockers: [], commands: [ "configuration-command" ], rollback: [ "rollback-command" ], verify: [], references: [] } ], counts: { "candidate" => 1 } }
      plain = Vxlan::CLI::Report.new(File.join(root, "plain"))
      plain.write_review(document, basename: "test", source: "test", source_sha256: "a" * 64, advice: advice)
      expect(Dir[File.join(plain.directory, "scripts", "*.cfg")]).to be_empty
      expect(File.read(File.join(plain.directory, "devices", "test.txt"))).not_to include("configuration-command")
      scripted = Vxlan::CLI::Report.new(File.join(root, "scripted"), scripts: true)
      scripted.write_review(document, basename: "test", source: "test", source_sha256: "a" * 64, advice: advice)
      expect(Dir[File.join(scripted.directory, "scripts", "*.cfg")].size).to eq(1)
      expect(File.read(File.join(scripted.directory, "devices", "test.txt"))).to include("configuration-command", "rollback-command")
    end
  end
end
