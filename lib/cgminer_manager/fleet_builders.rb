# frozen_string_literal: true

require 'cgminer_api_client'

module CgminerManager
  # Pure factories for PoolManager / CgminerCommander instances. Takes
  # the thread cap as an explicit argument rather than reaching into
  # Sinatra settings — HttpApp wrappers thread `settings.pool_thread_cap`
  # through. `thread_cap:` is defended against nil via `||= 1` at each
  # entry point so a future caller that forgets to supply it doesn't
  # blow up deep inside threaded fan-out.
  module FleetBuilders
    module_function

    def pool_manager_for_all(configured_miners:, thread_cap:)
      thread_cap ||= 1
      miners = miners_from(configured_miners)
      PoolManager.new(miners, thread_cap: thread_cap)
    end

    def pool_manager_for(miner_ids)
      miners = miner_ids.map { |id| miner_from_id(id) }
      PoolManager.new(miners)
    end

    def commander_for_all(configured_miners:, thread_cap:)
      thread_cap ||= 1
      miners = miners_from(configured_miners)
      CgminerCommander.new(miners: miners, thread_cap: thread_cap)
    end

    def commander_for(miner_ids, thread_cap:)
      thread_cap ||= 1
      miners = miner_ids.map { |id| miner_from_id(id) }
      CgminerCommander.new(miners: miners, thread_cap: thread_cap)
    end

    def miners_from(configured_miners)
      configured_miners.map do |host, port|
        CgminerApiClient::Miner.new(host, port)
      end
    end
    private_class_method :miners_from

    def miner_from_id(id)
      host, port = id.split(':', 2)
      CgminerApiClient::Miner.new(host, port.to_i)
    end
    private_class_method :miner_from_id
  end
end
