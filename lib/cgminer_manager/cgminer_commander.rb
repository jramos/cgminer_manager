# frozen_string_literal: true

require 'cgminer_api_client'

module CgminerManager
  # Fans out cgminer RPC commands across a miner set with a thread-cap bound.
  # Used by the Admin surface for fleet-wide or single-miner operations that
  # are not pool-management writes (those live in PoolManager).
  #
  # Read methods (version/stats/devs) return FleetQueryResult.
  # Write methods (zero!/save!/restart!/quit!/raw!) return FleetWriteResult.
  #
  # cgminer status codes: Miner#query raises ApiError on STATUS 'E' (error) or
  # 'F' (fatal). STATUS 'I' (info) and 'W' (warning) return normally and the
  # raw response is attached to the entry; operators see the warning text in
  # the response column of the rendered result table.
  class CgminerCommander
    def initialize(miners:, thread_cap: 8)
      @miners     = miners
      @thread_cap = thread_cap
    end

    def version = fan_out_query(:version)
    def stats   = fan_out_query(:stats)
    def devs    = fan_out_query(:devs)

    def zero!    = fan_out_write { |m| m.query(:zero, 'all', 'false') }
    def save!    = fan_out_write { |m| m.query(:save) }
    def restart! = fan_out_write { |m| m.query(:restart) }
    def quit!    = fan_out_write { |m| m.query(:quit) }

    def raw!(command:, args: nil)
      verb = command.to_sym
      positional = args.to_s.empty? ? [] : args.to_s.split(',')
      fan_out_write { |m| m.query(verb, *positional) }
    end

    private

    def fan_out_query(command)
      entries = ThreadedFanOut.map(@miners, thread_cap: @thread_cap) do |miner|
        response = miner.query(command)
        FleetQueryEntry.new(miner: miner.to_s, ok: true, response: response, error: nil)
      rescue CgminerApiClient::ConnectionError,
             CgminerApiClient::TimeoutError,
             CgminerApiClient::ApiError => e
        FleetQueryEntry.new(miner: miner.to_s, ok: false, response: nil, error: e)
      end
      FleetQueryResult.new(entries: entries)
    end

    def fan_out_write(&block)
      entries = ThreadedFanOut.map(@miners, thread_cap: @thread_cap) do |miner|
        response = block.call(miner)
        FleetWriteEntry.new(miner: miner.to_s, status: :ok, response: response, error: nil)
      rescue CgminerApiClient::ConnectionError,
             CgminerApiClient::TimeoutError,
             CgminerApiClient::ApiError => e
        FleetWriteEntry.new(miner: miner.to_s, status: :failed, response: nil, error: e)
      end
      FleetWriteResult.new(entries: entries)
    end
  end
end
