# frozen_string_literal: true

module CgminerManager
  # Thread-capped parallel map. Runs `items` through a worker pool of
  # at most `thread_cap` threads, collects per-item block results, and
  # returns them in input order.
  #
  # Callers own per-item error capture in their block (wrap in an Entry,
  # return a sentinel, etc.). If a block *does* raise an unhandled
  # exception, the helper records the first failure, signals sibling
  # workers to stop draining the queue, joins all threads, and re-raises
  # on the calling thread. That gives a crisp "one failure unwinds the
  # whole fan-out" contract — siblings don't keep firing side effects
  # after the caller has seen the exception.
  #
  # `thread_cap:` must be a non-nil Integer. Callers that want a nil
  # default must coalesce at their own call site — e.g. ViewModels
  # passes `thread_cap: pool_thread_cap || 1`. Keeping the helper strict
  # surfaces configuration bugs loudly.
  #
  # Caller blocks are responsible for their own thread-safety around any
  # closed-over state; the helper only serializes the `results[index] =`
  # write.
  module ThreadedFanOut
    module_function

    def map(items, thread_cap:, &block)
      validate_args!(thread_cap, block)
      return [] if items.empty?

      state = build_state(items)
      worker_count = clamp_workers(thread_cap, items.size)

      threads = Array.new(worker_count) do
        Thread.new { drain(state, &block) }
      end
      threads.each(&:join)
      raise state[:failure].first if state[:failure].first

      state[:results]
    end

    def validate_args!(thread_cap, block)
      raise ArgumentError, 'thread_cap must not be nil' if thread_cap.nil?
      raise ArgumentError, 'block required' unless block
    end
    private_class_method :validate_args!

    def clamp_workers(thread_cap, item_count)
      [thread_cap, item_count].min.clamp(1, item_count)
    end
    private_class_method :clamp_workers

    def build_state(items)
      # Enqueue (index, item) pairs so workers write to `results[index]`
      # directly. Avoids building an `item => index` hash, which would
      # collapse entries when two items are `==`-equal.
      queue = Queue.new
      items.each_with_index { |item, i| queue << [i, item] }
      {
        queue: queue,
        results: Array.new(items.size),
        mutex: Mutex.new,
        # Boxed in a 1-element array so closures can mutate across threads.
        failure: [nil]
      }
    end
    private_class_method :build_state

    def drain(state, &block)
      loop do
        break if state[:failure].first

        pair = pop_or_break(state[:queue]) or break
        index, item = pair
        begin
          result = block.call(item)
        rescue StandardError => e
          state[:mutex].synchronize { state[:failure][0] ||= e }
          break
        end
        state[:mutex].synchronize { state[:results][index] = result }
      end
    end
    private_class_method :drain

    def pop_or_break(queue)
      # ThreadError from Queue#pop(true) is the normal empty-queue
      # signal; nothing else should be swallowed here.
      queue.pop(true)
    rescue ThreadError
      nil
    end
    private_class_method :pop_or_break
  end
end
