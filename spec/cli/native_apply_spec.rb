# frozen_string_literal: true

require_relative "../spec_helper"
require "vxlan/cli"
require "vxlan/cli/apply"
require "net/connector"
require "tmpdir"
require "stringio"
require "rbconfig"

RSpec.describe "Native interactive configuration boundary" do
  # 本地 PTY 模拟模式切换及 running-config，不连接网络设备。
  class ApplyFixtureTransport < Net::Connector::Transports::Pty
    def argv
      program = <<~'RUBY'
        $stdout.sync = true
        bound, mode = false, false
        print "LEAF#"
        while (line = gets)
          command = line.strip
          print line
          mode = true if command == "configure terminal"
          mode = false if command == "end"
          bound = true if command == "ip access-group protect out"
          if command == "show running-config"
            puts "hostname LEAF\nvlan 8\n  vn-segment 10008\nvrf context tenant\ninterface Vlan8\n  vrf member tenant\n  ip address 192.0.2.254/24\n  fabric forwarding mode anycast-gateway"
            puts "  ip access-group protect out" if bound
            puts "ip access-list protect\n  10 deny ip any any\nend"
          end
          print(mode ? "LEAF(config)#" : "LEAF#")
        end
      RUBY
      [ RbConfig.ruby, "-e", program ]
    end
  end

  def terminal(text = "")
    stream = StringIO.new(text.dup)
    stream.define_singleton_method(:tty?) { true }
    stream
  end

  it "uses the installed connector for mode changes, leased execution, readback and closure" do
    Dir.mktmpdir do |root|
      settings = { username: "fixture-user", host_key_policy: "strict", command_timeout: 2, login_timeout: 2 }
      transport = ApplyFixtureTransport.new(Net::Connector::Configuration.new(host: "192.0.2.1", **settings))
      native = nil
      Net::Connector.open(:cisco_nxos, host: "192.0.2.1", **settings, transport: transport) do |device|
        native = device
        initial = device.with_operation(:fixture_setup) { Vxlan::CLI::ApplySession.new(device).read_configuration }
        change = { "kind" => "svi_acl", "vlan" => 8, "vni" => 10008, "acl" => "protect", "direction" => "out", "entries" => initial.fetch("acls").fetch("protect"), "create_acl" => false, "previous_binding" => nil }
        action = Vxlan::ChangePlan.build(change)
        commands, rollback = action.commands, action.rollback
        plan = { schema_version: 1, platform: "cisco_nxos", device: { host: "192.0.2.1", name: "LEAF" }, expected_config_sha256: Vxlan::ChangePlan.fingerprint(initial), change: change, commands: commands, rollback: rollback }
        body = JSON.generate(schema_version: 2, platform: "cisco_nxos", changes: { "attach-acl" => plan })
        hash = Digest::SHA256.hexdigest(body)
        path = File.join(root, "plan.json")
        File.write(path, body)
        File.write("#{path}.sha256", hash)
        out, error = terminal, terminal
        factory = lambda do |_target, _credentials, &operation|
          device.with_operation(:vxlan_apply) { operation.call(Vxlan::CLI::ApplySession.new(device)) }
        end
        status = Vxlan::CLI.run([ "apply", "--plan", path, "--item", "attach-acl", "--directory", File.join(root, "execution") ],
          discovery: { directories: [] }, env: { "NC_DEVICE_USERNAME" => "fixture-user" }, out: out, error: error, input: terminal("APPLY 192.0.2.1 #{hash[0, 12]} attach-acl\n"), connector_factory: factory)
        expect(status).to eq(0), error.string
        journal = JSON.parse(File.read(Dir[File.join(root, "execution/*/execution.json")].fetch(0)))
        expect(journal).to include("status" => "configuration_verified", "plan_item" => "attach-acl")
        expect(journal.fetch("steps").size).to eq(commands.size)
        expect(Vxlan::CLI::ApplySession.new(device).read_configuration.dig("interfaces", "Vlan8", "acl_bindings", "out")).to eq("protect")
      end
      expect(native).not_to be_connected
    end
  end
end
