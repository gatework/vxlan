# frozen_string_literal: true

require_relative "../spec_helper"
require "vxlan/cli/report"
require "tmpdir"

RSpec.describe Vxlan::CLI::Report do
  around do |example|
    Dir.mktmpdir do |directory|
      @root = File.join(directory, "reports")
      example.run
    end
  end

  let(:result) { { device: { "host" => "192.0.2.10", "name" => "LEAF" }, status: :complete, dimensions: {} } }

  it "rejects a preexisting root accessible by other users" do
    Dir.mkdir(@root, 0o755)
    expect { described_class.new(@root) }.to raise_error(ArgumentError, /0700/)
    expect(Dir.children(@root)).to be_empty
    expect(File.stat(@root).mode & 0o777).to eq(0o755)
  end

  it "rejects a symlink root without writing through it" do
    target = "#{@root}-target"
    Dir.mkdir(target, 0o700)
    File.symlink(target, @root)
    expect { described_class.new(@root) }.to raise_error(ArgumentError, /0700/)
    expect(Dir.children(target)).to be_empty
  end

  it "retains committed JSON and safe publication details when device text cannot be renamed" do
    report = described_class.new(@root)
    original = File.method(:rename)
    allow(File).to receive(:rename) do |source, target|
      raise Errno::ENOSPC, "private-file-detail" if target.end_with?(".txt")
      original.call(source, target)
    end
    expect { report.write(result) }.to raise_error(IOError) { |error|
      expect(error.class.name).to eq("Vxlan::CLI::Report::Error")
      expect(error.relative).to eq("devices/LEAF-192.0.2.10.txt")
      expect(error.phase).to eq(:rename)
      expect(error).not_to be_committed
      expect(error.message + error.inspect).not_to include("private-file-detail")
    }
    expect(File).to exist("#{report.directory}/devices/LEAF-192.0.2.10.json")
    expect(Dir["#{report.directory}/devices/.*.tmp"]).to be_empty
  end

  it "distinguishes committed output from confirmed directory durability" do
    report = described_class.new(@root)
    original = File.method(:open)
    allow(File).to receive(:open) do |*args, **kwargs, &operation|
      next original.call(*args, **kwargs) unless operation
      original.call(*args, **kwargs) do |file|
        allow(file).to receive(:fsync).and_raise(Errno::EINVAL, "private-sync-detail") if file.stat.directory?
        operation.call(file)
      end
    end
    expect { report.write(result) }.to raise_error(IOError) { |error|
      expect(error.class.name).to eq("Vxlan::CLI::Report::Error")
      expect(error.phase).to eq(:directory_sync)
      expect(error).to be_committed
      expect(error.message).not_to include("private-sync-detail")
    }
    expect(File).to exist("#{report.directory}/devices/LEAF-192.0.2.10.json")
  end

  it "syncs each published file and its containing directory with private permissions" do
    report = described_class.new(@root)
    synced = []
    original = File.method(:open)
    allow(File).to receive(:open) do |*args, **kwargs, &operation|
      next original.call(*args, **kwargs) unless operation
      original.call(*args, **kwargs) do |file|
        allow(file).to receive(:fsync).and_wrap_original do |sync|
          synced << file.path if file.stat.directory?
          sync.call
        end
        operation.call(file)
      end
    end
    report.write(result)
    report.finish([ result ], requested: [ result.fetch(:device) ])
    expect(synced).to eq([ "#{report.directory}/devices" ] * 2 + [ report.directory ] * 2)
    Dir["#{report.directory}/**/*"].each do |path|
      expect(File.stat(path).mode & 0o777).to eq(File.directory?(path) ? 0o700 : 0o600)
    end
  end

  it "does not report complete when requested targets have never been collected" do
    report = described_class.new(@root)
    missing = { "host" => "192.0.2.11", "name" => "SPARE" }
    summary = report.finish([ result ], requested: [ result.fetch(:device), missing ])
    expect(summary[:status]).to eq(:incomplete)
    expect(summary[:pending]).to eq([ missing ])
  end
end
