# frozen_string_literal: true

module CgminerManager
  # Thread-capped parallel map. Runs `items` through a worker pool of
  # at most `thread_cap` threads, collects per-item block results, and
  # returns them in input order.
  #
  # Error handling lives in the caller's block — unhandled exceptions
  # bubble up via Thread#join. When one worker raises, the calling
  # thread re-raises on join, but sibling workers keep draining the
  # queue until it empties (no mid-flight interrupt). That matches
  # the semantics of the three fan-out sites this helper replaces:
  # CgminerCommander#fan_out_query/#fan_out_write, PoolManager#run_each,
  # ViewModels.fetch_snapshots_for.
  #
  # `thread_cap:` must be a non-nil Integer. Callers that want a nil
  # default must coalesce at their own call site — e.g. ViewModels
  # passes `thread_cap: pool_thread_cap || 1`. Keeping the helper
  # strict surfaces configuration bugs loudly.
  module ThreadedFanOut
    module_function

    def map(items, thread_cap:, &block)
      raise ArgumentError, 'thread_cap must not be nil' if thread_cap.nil?
      return [] if items.empty?

      worker_count = [thread_cap, items.size].min
      worker_count = 1 if worker_count < 1

      # Enqueue (index, item) pairs so workers write to `results[index]`
      # directly. Avoids an items-to-index hash (O(n) + collapses when
      # two items are `==`-equal).
      queue = Queue.new
      items.each_with_index { |item, i| queue << [i, item] }
      results = Array.new(items.size)
      mutex = Mutex.new

      threads = Array.new(worker_count) do
        Thread.new { drain(queue, results, mutex, &block) }
      end
      threads.each(&:join)
      results
    end

    def drain(queue, results, mutex, &block)
      loop do
        pair = pop_or_break(queue) or break
        index, item = pair
        result = block.call(item)
        mutex.synchronize { results[index] = result }
      end
    end
    private_class_method :drain

    def pop_or_break(queue)
      queue.pop(true)
    rescue ThreadError
      nil
    end
    private_class_method :pop_or_break
  end
end
