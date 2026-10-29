# frozen_string_literal: true

require_relative "../spec_helper"
require "vxlan/cli"
require "vxlan/cli/apply"
require "vxlan/cli/report"
require "vxlan/change_plan"
require "tmpdir"
require "stringio"
require "digest"
require "json"

RSpec.describe "Vxlan interactive apply" do
  let(:config) { { "vlan_vnis" => { "8" => 10008 }, "interfaces" => { "Vlan8" => { "addresses" => [ "192.0.2.254/24" ], "vrf" => "tenant", "anycast" => true, "acl_bindings" => {} } }, "acls" => { "protect" => [ { "sequence" => 10, "action" => "deny", "expression" => "ip any any" } ] } } }
  let(:change) { { "kind" => "svi_acl", "vlan" => 8, "vni" => 10008, "acl" => "protect", "direction" => "out", "entries" => config["acls"]["protect"], "create_acl" => false, "previous_binding" => nil } }
  let(:after_config) do
    updated = Marshal.load(Marshal.dump(config))
    updated["interfaces"]["Vlan8"]["acl_bindings"]["out"] = "protect"
    updated
  end

  # 模拟真实终端及设备边界，避免单元测试接触网络。
  def terminal(text = "")
    stream = StringIO.new(text.dup)
    stream.define_singleton_method(:tty?) { true }
    stream
  end

  # 真实解析器生成完整事实，确保回读差异没有被合成结构的缺字段掩盖。
  def parsed_configuration(text)
    observation = Vxlan::Config.new.parse(text, complete: true)
    expect(observation).to be_complete
    JSON.parse(JSON.generate(observation.records.fetch(0)))
  end

  def exercise(env: nil, confirmation: true, tty: true, drift: false, fail_write: false, altered: false, persistence_failure: false, failed_readback: false, checkpoint_failure: false, batch: true, item: "test-change", bad_checksum: false, confirmation_item: nil, callbacks: 1, close_failure: false, reuse_readback: false, broken_error: false, interrupted_write: false)
    Dir.mktmpdir do |root|
      action = Vxlan::ChangePlan.build(change)
      commands, rollback = action.commands, action.rollback
      plan = { schema_version: 3, kind: "change", platform: "cisco_nxos", device: { "host" => "192.0.2.1", "name" => "test" }, expected_config_sha256: CtxRunner::Fingerprint.call(config), change: change, commands: commands, rollback: rollback, prerequisites: [], impact: "test" }
      plan[:commands] = [ "reboot" ] if altered
      path = File.join(root, "plan.json")
      document = batch ? { schema_version: 3, kind: "change_plan", platform: "cisco_nxos", changes: { "test-change" => plan, "other-change" => plan.merge(device: { "host" => "192.0.2.2", "name" => "other" }) } } : plan
      File.write(path, JSON.generate(document))
      File.write("#{path}.sha256", bad_checksum ? "0" * 64 : Digest::SHA256.file(path).hexdigest) if batch
      token = "APPLY 192.0.2.1 #{Digest::SHA256.file(path).hexdigest[0, 12]}"
      token += " #{confirmation_item || item}" if batch
      input = tty ? terminal(confirmation ? "#{token}\n" : "no\n") : StringIO.new("#{token}\n")
      out, error = terminal, terminal
      error.define_singleton_method(:puts) { |*| raise IOError, "private-diagnostic-failure" } if broken_error
      writes, connections, credentials = [], [], []
      before, after = config, failed_readback ? config : after_config
      session = Object.new
      session.define_singleton_method(:read_configuration) do
        writes.empty? ? (drift ? before.merge("drift" => true) : before) : (reuse_readback ? before.replace(after) : after)
      end
      session.define_singleton_method(:write) do |command|
        writes << command
        raise Interrupt, "private-interruption-detail" if interrupted_write
        raise IOError, "private-error-detail" if fail_write
        true
      end
      factory = lambda do |device, settings, &block|
        connections << device
        credentials << settings
        callbacks.times { block.call(session) }
        raise IOError, "private-close-detail" if close_failure
      end
      if persistence_failure
        allow_any_instance_of(Vxlan::CLI::Report).to receive(:write_execution).and_raise(Errno::ENOSPC)
      end
      if checkpoint_failure
        count = 0
        allow_any_instance_of(Vxlan::CLI::Report).to receive(:write_execution).and_wrap_original do |original, state|
          count += 1
          raise Errno::ENOSPC if count == 3
          original.call(state)
        end
      end
      args = [ "apply", "--plan", path, "--directory", File.join(root, "execution") ]
      args.concat([ "--item", item ]) if batch && item
      status = Vxlan::CLI.run(args, discovery: { directories: [] }, env: env || { "NC_DEVICE_USERNAME" => "test" }, out: out, error: error, input: input, connector_factory: factory)
      journals = Dir[File.join(root, "execution", "*", "execution.json")].map { |file| JSON.parse(File.read(file)) }
      { status: status, writes: writes, connections: connections, journals: journals, error: error.string, credentials: credentials }
    end
  end

  it "uses common credentials for empty platform overrides and keeps the platform enable password" do
    result = exercise(env: { "NC_DEVICE_USERNAME" => "shared-user", "NC_DEVICE_PASSWORD" => "shared-secret",
      "NC_CISCO_NXOS_USERNAME" => "", "NC_CISCO_NXOS_PASSWORD" => "", "NC_ENABLE_PASSWORD" => "common-enable",
      "NC_CISCO_NXOS_ENABLE_PASSWORD" => "platform-enable" })
    expect(result[:status]).to eq(0), result[:error]
    expect(result[:credentials]).to contain_exactly(include(username: "shared-user", password: "shared-secret", enable_password: "platform-enable"))
    expect(result[:journals].to_s + result[:error]).not_to include("shared-secret", "platform-enable")
  end

  it "returns a preflight failure without connecting when stderr is unavailable" do
    expect(exercise(tty: false, broken_error: true)).to include(status: 2, connections: [], writes: [], journals: [])
  end

  it "retains intent failure when journal recovery and stderr both fail" do
    expect(exercise(persistence_failure: true, broken_error: true)).to include(status: 2, connections: [], writes: [], journals: [])
  end

  it "keeps a failed command uncertain without replay when stderr is unavailable" do
    result = exercise(fail_write: true, broken_error: true)
    expect(result[:status]).to eq(2)
    expect(result[:writes].size).to eq(1)
    expect(result[:journals].last).to include("status" => "uncertain", "pending_command" => 0, "steps" => [])
  end

  it "preserves cancellation and its journal when stderr is unavailable" do
    result = exercise(interrupted_write: true, broken_error: true)
    expect(result[:status]).to eq(130)
    expect(result[:writes].size).to eq(1)
    expect(result[:journals].last).to include("status" => "uncertain", "error" => "interrupted", "pending_command" => 0)
  end

  it "shows help without consuming input and rejects unexpected positional arguments" do
    input, out, error = StringIO.new("unread\n"), StringIO.new, StringIO.new
    connections = []
    factory = ->(*) { connections << true }
    cli = Vxlan::CLI::Apply.new(env: {}, discovery: { directories: [] }, input: input, out: out, error: error, connector_factory: factory)
    expect(cli.run([ "--help" ])).to eq(0)
    expect(out.string).to include("--plan", "--item")
    expect(cli.run([ "--help", "unexpected" ])).to eq(2)
    expect(input.pos).to eq(0)
    expect(connections).to be_empty
  end

  it "rejects an oversized plan before confirmation or connection" do
    require "ctx_cli/input"
    stub_const("CtxCli::Input::MAX_BYTES", 32)
    expect(exercise).to include(status: 2, connections: [], writes: [], journals: [])
  end

  it "requires a specific item from an aggregate plan and rejects unknown selection" do
    expect(exercise(batch: true, item: nil)).to include(status: 2, connections: [], writes: [])
    expect(exercise(batch: true, item: "missing")).to include(status: 2, connections: [], writes: [])
  end

  it "captures an independent starting snapshot when a reader reuses its result hash" do
    expect(exercise(reuse_readback: true)[:status]).to eq(0)
  end

  it "does not connect when the execution directory entry cannot be made durable" do
    original = File.method(:open)
    allow(File).to receive(:open) do |*args, **kwargs, &operation|
      next original.call(*args, **kwargs) unless operation
      original.call(*args, **kwargs) do |file|
        allow(file).to receive(:fsync).and_raise(Errno::EIO) if File.basename(file.path) == "execution"
        operation.call(file)
      end
    end
    expect(exercise).to include(status: 2, connections: [], writes: [], journals: [])
  end

  it "rejects standalone legacy plans instead of bypassing the batch checksum contract" do
    expect(exercise(batch: false)).to include(status: 2, connections: [], writes: [])
  end

  it "does not report configuration verification when the connector never opens a session" do
    result = exercise(callbacks: 0)
    expect(result).to include(status: 2, writes: [])
    expect(result[:journals].last).to include("status" => "failed")
  end

  it "never replays an operation if the connector yields its session more than once" do
    result = exercise(callbacks: 2)
    expect(result[:status]).to eq(2)
    expect(result[:writes]).to eq(Vxlan::ChangePlan.build(change).commands)
    expect(result[:journals].last).to include("status" => "uncertain")
  end

  it "preserves verified facts but reports uncertainty when session finalization fails" do
    result = exercise(close_failure: true)
    expect(result[:status]).to eq(2)
    expect(result[:journals].last).to include("status" => "uncertain", "observed_config_sha256" => CtxRunner::Fingerprint.call(after_config))
    expect(result[:error]).not_to include("private-close-detail")
  end

  it "rejects a changed aggregate plan checksum before opening a session" do
    expect(exercise(batch: true, bad_checksum: true)).to include(status: 2, connections: [], writes: [])
  end

  it "binds interactive confirmation to the selected item as well as the batch" do
    expect(exercise(batch: true, confirmation_item: "other-change")).to include(status: 1, connections: [], writes: [])
  end

  it "executes only the selected aggregate item and records its identity" do
    result = exercise(batch: true)
    expect(result[:status]).to eq(0), result[:error]
    expect(result[:connections].map { |device| device["host"] }).to eq([ "192.0.2.1" ])
    expect(result[:journals].last).to include("plan_item" => "test-change", "status" => "configuration_verified")
  end

  context "with a proven missing VLAN/VNI association" do
    let(:config) do
      { "vlan_vnis" => { "8" => nil }, "interfaces" => { "Vlan8" => { "addresses" => [ "192.0.2.254/24" ], "vrf" => "tenant", "anycast" => true } },
        "nve" => { "members" => { "10008" => { "associate_vrf" => false } } }, "evpn" => { "10008" => { "type" => "l2" } } }
    end
    let(:change) { { "kind" => "vlan_vni_add", "vlan" => 8, "vni" => 10008, "vrf" => "tenant", "address" => "192.0.2.254/24" } }
    let(:after_config) { config.merge("vlan_vnis" => { "8" => 10008 }) }

    it "uses the same confirmation, durable journal, and readback boundary as ACL changes" do
      expect(exercise(batch: true, confirmation: false)).to include(status: 1, connections: [], writes: [])
      result = exercise(batch: true)
      expect(result).to include(status: 0, writes: [ "configure terminal", "vlan 8", "  vn-segment 10008", "end" ])
      expect(result[:journals].last["status"]).to eq("configuration_verified")
      expect(exercise(batch: true, failed_readback: true)[:journals].last["status"]).to eq("uncertain")
    end

    context "when readback maps another VLAN to the same VNI" do
      let(:after_config) { config.merge("vlan_vnis" => { "8" => 10008, "9" => 10008 }) }

      it "keeps the completed command sequence uncertain instead of verifying a duplicate mapping" do
        result = exercise
        expect(result[:status]).to eq(2)
        expect(result[:journals].last["status"]).to eq("uncertain")
        expect(result[:writes]).to eq([ "configure terminal", "vlan 8", "  vn-segment 10008", "end" ])
      end
    end

    context "when parsed readback silently changes the existing access policy" do
      let(:configuration_text) do
        <<~CLI
          hostname LEAF
          fabric forwarding anycast-gateway-mac 0001.0001.0001
          vlan 8
            name SERVICE
          vrf context tenant
          interface Vlan8
            vrf member tenant
            ip address 192.0.2.254/24
            fabric forwarding mode anycast-gateway
            ip access-group protect out
          interface nve1
            member vni 10008
              ingress-replication protocol bgp
          evpn
            vni 10008 l2
              rd auto
              route-target import auto
              route-target export auto
          ip access-list protect
            10 deny ip any any
          end
        CLI
      end
      let(:config) { parsed_configuration(configuration_text) }
      let(:after_config) do
        parsed_configuration(configuration_text.sub("vlan 8\n", "vlan 8\n  vn-segment 10008\n").sub("  ip access-group protect out\n", ""))
      end

      it "keeps the result uncertain despite a complete parser result and the requested VNI" do
        result = exercise
        expect(result[:status]).to eq(2)
        expect(result[:journals].last["status"]).to eq("uncertain")
        expect(result[:writes]).to eq(Vxlan::ChangePlan.build(change).commands)
      end

      it "accepts the intended association despite changed digest and derived segment metadata" do
        after = parsed_configuration(configuration_text.sub("vlan 8\n", "vlan 8\n  vn-segment 10008\n"))
        fingerprint = CtxRunner::Fingerprint.call(config)
        expect(after["config_digest"]).not_to eq(config["config_digest"])
        expect(after["segments"]).not_to eq(config["segments"])
        expect(Vxlan::ChangePlan.build(change).satisfied?(after, before: config)).to be(true)
        expect(CtxRunner::Fingerprint.call(config)).to eq(fingerprint)
      end
    end
  end

  context "when an existing gateway identity changes during ACL application" do
    let(:config) { super().merge("anycast_mac" => "0001.0001.0001") }
    let(:after_config) { super().merge("anycast_mac" => "0002.0002.0002") }

    it "does not verify a target binding while unrelated business facts have changed" do
      result = exercise
      expect(result[:status]).to eq(2)
      expect(result[:journals].last["status"]).to eq("uncertain")
    end
  end

  context "when creating an ACL activates an unplanned interface in readback" do
    let(:config) { super().merge("acls" => {}) }
    let(:change) { super().merge("entries" => [ { "sequence" => 10, "action" => "deny", "expression" => "ip any any" } ], "create_acl" => true) }
    let(:after_config) do
      super().merge("acls" => { "protect" => change["entries"] }).tap do |updated|
        updated["interfaces"]["Ethernet1/1"] = { "acl_bindings" => { "in" => "protect" } }
      end
    end

    it "records uncertainty after all commands without retrying or rolling back" do
      result = exercise
      expect(result[:status]).to eq(2)
      expect(result[:journals].last["status"]).to eq("uncertain")
      expect(result[:writes]).to eq([ "configure terminal", "ip access-list protect", "  10 deny ip any any", "exit", "interface Vlan8", "  ip access-group protect out", "end" ])
    end
  end

  context "with a proven missing primary gateway" do
    let(:config) { super().tap { |value| value["interfaces"]["Vlan8"]["addresses"] = [] } }
    let(:change) { { "kind" => "svi_gateway_add", "vlan" => 8, "vni" => 10008, "vrf" => "tenant", "address" => "192.0.2.254/24" } }
    let(:after_config) do
      Marshal.load(Marshal.dump(config)).tap { |value| value["interfaces"]["Vlan8"]["addresses"] = [ "192.0.2.254/24" ] }
    end

    it "verifies the single planned address" do
      expect(exercise[:status]).to eq(0)
    end

    context "when readback includes an unplanned additional address" do
      let(:after_config) { super().tap { |value| value["interfaces"]["Vlan8"]["addresses"] << "198.51.100.254/24" } }

      it "keeps the gateway effect uncertain" do
        result = exercise
        expect(result[:status]).to eq(2)
        expect(result[:journals].last["status"]).to eq("uncertain")
        expect(result[:writes]).to eq([ "configure terminal", "interface Vlan8", "  ip address 192.0.2.254/24", "end" ])
      end
    end

    context "when another interface overlaps the planned address during execution" do
      let(:after_config) { super().tap { |value| value["interfaces"]["Vlan9"] = { "vrf" => "tenant", "addresses" => [ "192.0.2.129/25" ] } } }

      it "keeps the overlapping gateway effect uncertain" do
        result = exercise
        expect(result[:status]).to eq(2)
        expect(result[:journals].last["status"]).to eq("uncertain")
        expect(result[:writes].size).to eq(4)
      end
    end
  end

  it "requires an exact interactive confirmation and never connects on cancellation" do
    result = exercise(confirmation: false)
    expect(result).to include(status: 1, connections: [], writes: [])
  end

  it "rejects piped confirmations before connecting" do
    expect(exercise(tty: false)).to include(status: 2, connections: [], writes: [])
  end

  it "rejects drift after reading but before any configuration command" do
    expect(exercise(drift: true)).to include(status: 2, writes: [])
  end

  it "does not execute arbitrary edited commands from a plan" do
    expect(exercise(altered: true)).to include(status: 2, connections: [], writes: [])
  end

  it "writes no commands when durable intent cannot be saved" do
    expect(exercise(persistence_failure: true)).to include(status: 2, writes: [])
  end

  it "stops on the first uncertain command without retry or rollback" do
    result = exercise(fail_write: true)
    expect(result[:status]).to eq(2)
    expect(result[:writes].size).to eq(1)
    expect(result[:journals].last).to include("status" => "uncertain")
    expect(result[:error]).not_to include("private-error-detail")
  end

  it "does not claim success when the readback still has the original configuration" do
    result = exercise(failed_readback: true)
    expect(result[:status]).to eq(2)
    expect(result[:journals].last).to include("status" => "uncertain")
  end

  it "stops after the first command if its acknowledgement cannot be persisted" do
    result = exercise(checkpoint_failure: true)
    expect(result[:status]).to eq(2)
    expect(result[:writes].size).to eq(1)
    expect(result[:journals].last).to include("status" => "uncertain")
  end

  it "confirms completion only after a configuration readback" do
    result = exercise
    expect(result[:status]).to eq(0), result[:error]
    expect(result[:journals].last).to include("status" => "configuration_verified")
    expect(result[:writes].last).to eq("end")
  end
end
