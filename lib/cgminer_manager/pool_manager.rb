# frozen_string_literal: true

require 'cgminer_api_client'

module CgminerManager
  class PoolManager
    MinerEntry = Data.define(:miner, :command_status, :command_reason,
                             :save_status, :save_reason) do
      def ok?     = command_status == :ok && save_status == :ok
      def failed? = command_status == :failed
    end

    PoolActionResult = Data.define(:entries) do
      def all_ok?       = entries.all?(&:ok?)
      def any_failed?   = entries.any?(&:failed?)
      def successful    = entries.select(&:ok?)
      def failed        = entries.select(&:failed?)
      def indeterminate = entries.select { |e| e.command_status == :indeterminate }
    end

    def initialize(miners, thread_cap: 8)
      @miners     = miners
      @thread_cap = thread_cap
    end

    def disable_pool(pool_index:)
      run_each do |miner|
        run_verified(miner) do
          miner.disablepool(pool_index)
          verify_pool_state(miner, pool_index, 'Disabled')
        end
      end
    end

    def enable_pool(pool_index:)
      run_each do |miner|
        run_verified(miner) do
          miner.enablepool(pool_index)
          verify_pool_state(miner, pool_index, 'Alive')
        end
      end
    end

    def remove_pool(pool_index:)
      run_each do |miner|
        run_verified(miner) do
          miner.removepool(pool_index)
          verify_pool_absent(miner, pool_index)
        end
      end
    end

    def add_pool(url:, user:, pass:)
      run_each do |miner|
        run_unverified(miner) do
          miner.addpool(url, user, pass)
        end
      end
    end

    def save
      run_each do |miner|
        run_unverified(miner) do
          miner.query(:save)
        end
      end
    end

    private

    def run_each(&block)
      queue = Queue.new
      @miners.each { |m| queue << m }

      results = Array.new(@miners.size)
      index_of = @miners.each_with_index.to_h
      mutex = Mutex.new

      worker_count = [@thread_cap, @miners.size].min
      worker_count = 1 if worker_count < 1

      workers = worker_count.times.map do
        Thread.new do
          loop do
            miner =
              begin
                queue.pop(true)
              rescue ThreadError
                break
              end
            entry = block.call(miner)
            mutex.synchronize { results[index_of[miner]] = entry }
          end
        end
      end
      workers.each(&:join)

      PoolActionResult.new(entries: results)
    end

    def run_verified(miner, &)
      command_status, command_reason = safe_call(&)
      save_status, save_reason =
        if command_status == :failed
          [:skipped, nil]
        else
          safe_call { miner.query(:save) }
        end

      MinerEntry.new(miner: miner.to_s,
                     command_status: command_status, command_reason: command_reason,
                     save_status: save_status, save_reason: save_reason)
    end

    def run_unverified(miner, &)
      command_status, command_reason = safe_call(&)
      save_status = :skipped
      save_reason = nil
      MinerEntry.new(miner: miner.to_s,
                     command_status: command_status, command_reason: command_reason,
                     save_status: save_status, save_reason: save_reason)
    end

    def safe_call
      yield
      [:ok, nil]
    rescue PoolManagerError::DidNotConverge => e
      [:indeterminate, e]
    rescue CgminerApiClient::ConnectionError,
           CgminerApiClient::TimeoutError,
           CgminerApiClient::ApiError => e
      [:failed, e]
    end

    def verify_pool_state(miner, pool_index, expected)
      pool = find_pool(miner, pool_index)
      return if pool && pool['STATUS'] == expected

      raise PoolManagerError::DidNotConverge,
            "pool #{pool_index} did not reach #{expected}; observed #{pool.inspect}"
    rescue CgminerApiClient::ConnectionError, CgminerApiClient::TimeoutError
      raise PoolManagerError::DidNotConverge, "verification query timed out for pool #{pool_index}"
    end

    def verify_pool_absent(miner, pool_index)
      pool = find_pool(miner, pool_index)
      return unless pool

      raise PoolManagerError::DidNotConverge, "pool #{pool_index} still present after remove"
    rescue CgminerApiClient::ConnectionError, CgminerApiClient::TimeoutError
      raise PoolManagerError::DidNotConverge, "verification query timed out for pool #{pool_index}"
    end

    def find_pool(miner, pool_index)
      miner.query(:pools).detect { |p| p['POOL'].to_s == pool_index.to_s }
    end
  end
end
