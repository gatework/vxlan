# frozen_string_literal: true

module Vxlan
  module CLI
    # 宿主拥有设备并发与线程回收，不依赖可选连接器的内部调度类。
    module Parallel
      # 全部线程登记后才放行；任务异常或取消时停止并等待本批全部线程。
      def self.map(items, parallel:, &operation)
        prepare_resources([ items.size, parallel ].min)
        jobs, finished, gate = Queue.new, Queue.new, Queue.new
        items.each_with_index { |item, index| jobs << [ item, index ] }
        count = [ items.size, parallel ].min
        count.times { jobs << nil }
        results, threads = Array.new(items.size), []
        primary_failure = nil
        begin
          Thread.handle_interrupt(Exception => :never) do
            count.times do
              threads << Thread.new do
                failure, exhausted = nil, false
                begin
                  Thread.handle_interrupt(Exception => :immediate) do
                    gate.pop
                    while (job = jobs.pop)
                      item, index = job
                      results[index] = operation.call(item)
                    end
                    exhausted = true
                  end
                rescue Exception => error # rubocop:disable Lint/RescueException -- 跨线程交付取消与致命失败，再由所有者回收。
                  failure = error
                ensure
                  # Thread.exit/kill 绕过 rescue；只有耗尽任务才可交付正常完成。
                  failure ||= RuntimeError.new("collection worker stopped before completing its tasks") unless exhausted
                  finished << failure
                end
              end
            end
            count.times { gate << true }
          end
          count.times do
            failure = finished.pop
            raise failure if failure
          end
          results
        rescue Exception => error # rubocop:disable Lint/RescueException -- 回收时保留首先观察到的取消或任务失败。
          primary_failure = error
          raise
        ensure
          begin
            Thread.handle_interrupt(Exception => :never) do
              threads.each(&:kill)
              threads.each do |thread|
                thread.join
              rescue Exception => error # rubocop:disable Lint/RescueException -- 次级收尾故障不能阻止等待其他线程。
                primary_failure ||= error
              end
            end
          rescue Exception => error # rubocop:disable Lint/RescueException -- 屏蔽区退出时仍优先交付原始故障。
            primary_failure ||= error
          end
          raise primary_failure, cause: primary_failure.cause if primary_failure
        end
      end

      # 为每个 PTY 会话预留句柄；无法提高软限制时在连接前明确拒绝过高并发。
      def self.prepare_resources(parallel)
        return unless Process.const_defined?(:RLIMIT_NOFILE)
        needed = 64 + parallel * 8
        soft, hard = Process.getrlimit(:NOFILE)
        return if soft >= needed
        raise ArgumentError, "文件描述符上限不足，请降低 parallel 或提高 ulimit -n（至少 #{needed}）" if hard < needed

        Process.setrlimit(:NOFILE, needed, hard)
      rescue SystemCallError, NotImplementedError
        raise ArgumentError, "无法提高文件描述符上限，请降低 parallel 或提高 ulimit -n", cause: nil
      end
      private_class_method :prepare_resources
    end
  end
end
