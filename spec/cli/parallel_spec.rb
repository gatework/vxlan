# frozen_string_literal: true

require_relative "../spec_helper"
require "vxlan/cli/parallel"
require "timeout"

RSpec.describe Vxlan::CLI::Parallel do
  it "rejects a worker exiting without finishing its tasks" do
    expect { described_class.map([ 1 ], parallel: 1) { Thread.exit } }
      .to raise_error(RuntimeError, "collection worker stopped before completing its tasks")
  end

  it "rejects a killed worker and joins its blocked sibling" do
    started, stopped, blocked = Queue.new, Queue.new, Queue.new
    failure = nil
    owner = Thread.new do
      described_class.map([ 1, 2 ], parallel: 2) do
        begin
          started << Thread.current
          blocked.pop
        ensure
          stopped << Thread.current
        end
      end
    rescue Exception => error # rubocop:disable Lint/RescueException -- 将测试拥有线程的取消交给断言。
      failure = error
    end
    workers = 2.times.map { started.pop }
    workers.first.kill
    Timeout.timeout(2) { owner.join }
    expect(failure).to be_a(RuntimeError)
    expect(workers).to all(satisfy { |worker| !worker.alive? })
    expect(stopped.size).to eq(2)
  ensure
    owner&.kill&.join
  end

  it "keeps the original interrupt when a cancelled sibling raises during cleanup" do
    started, blocked, stopped = Queue.new, Queue.new, Queue.new
    original = Interrupt.new("primary cancellation")
    expect do
      Timeout.timeout(2) do
        described_class.map([ :failing, :blocked ], parallel: 2) do |item|
          if item == :failing
            started.pop
            raise original
          end
          begin
            started << true
            blocked.pop
          ensure
            stopped << true
            raise IOError, "secondary cleanup detail"
          end
        end
      end
    end.to raise_error { |error| expect(error).to equal(original) }
    expect(stopped.pop).to be(true)
  end

  it "stops and joins a blocked sibling when another task cannot persist its result" do
    started, blocked, stopped = Queue.new, Queue.new, Queue.new
    expect do
      Timeout.timeout(2) do
        described_class.map([ :failing, :blocked ], parallel: 2) do |item|
          if item == :failing
            started.pop
            raise IOError, "synthetic report failure"
          end
          begin
            started << true
            blocked.pop
          ensure
            stopped << true
          end
        end
      end
    end.to raise_error(IOError, "synthetic report failure")
    expect(stopped.pop).to be(true)
  end

  it "does not start any task when thread creation fails halfway through registration" do
    allow(Thread).to receive(:new).and_call_original
    original = Thread.method(:new)
    calls = 0
    allow(Thread).to receive(:new) do |&operation|
      calls += 1
      raise ThreadError, "synthetic thread exhaustion" if calls == 2
      original.call(&operation)
    end
    ran = Queue.new
    expect { described_class.map([ 1, 2 ], parallel: 2) { |value| ran << value } }.to raise_error(ThreadError)
    expect(ran).to be_empty
  end
end
