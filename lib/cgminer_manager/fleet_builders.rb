# frozen_string_literal: true

require 'cgminer_api_client'

module CgminerManager
  # Pure factories for PoolManager / CgminerCommander instances. Takes
  # the thread cap as an explicit argument rather than reaching into
  # Sinatra settings — HttpApp wrappers thread `settings.pool_thread_cap`
  # through. `thread_cap:` is defended against nil via `||= 1` at each
  # entry point so a future caller that forgets to supply it doesn't
  # blow up deep inside threaded fan-out.
  #
  # When a `request_id:` flows through, the factories build an `on_wire`
  # closure that captures it and tags `cgminer.wire` debug log events.
  # Closure is shared across all per-request Miner instances; threading
  # is safe because the closure has no mutable state and Ruby strings
  # are GC-stable. Wire events emit at debug level — opt in via
  # `LOG_LEVEL=debug` to avoid the ~100-200 events per fan-out at info
  # volume.
  module FleetBuilders
    module_function

    def pool_manager_for_all(configured_miners:, thread_cap:, request_id: nil)
      thread_cap ||= 1
      miners = miners_from(configured_miners, on_wire: build_wire_logger(request_id))
      PoolManager.new(miners, thread_cap: thread_cap)
    end

    # Deliberately no `thread_cap:` kwarg. Callers use this for
    # single-miner or handful-of-miners pool ops (triggered by a specific
    # admin UI click), so `PoolManager`'s own default of 8 is fine and
    # the cap is never the bottleneck. Keeps the call site terse.
    def pool_manager_for(miner_ids, request_id: nil)
      on_wire = build_wire_logger(request_id)
      miners = miner_ids.map { |id| miner_from_id(id, on_wire: on_wire) }
      PoolManager.new(miners)
    end

    def commander_for_all(configured_miners:, thread_cap:, request_id: nil)
      thread_cap ||= 1
      miners = miners_from(configured_miners, on_wire: build_wire_logger(request_id))
      CgminerCommander.new(miners: miners, thread_cap: thread_cap)
    end

    def commander_for(miner_ids, thread_cap:, request_id: nil)
      thread_cap ||= 1
      on_wire = build_wire_logger(request_id)
      miners = miner_ids.map { |id| miner_from_id(id, on_wire: on_wire) }
      CgminerCommander.new(miners: miners, thread_cap: thread_cap)
    end

    # Public so direct-Miner.new sites in HttpApp routes (e.g.
    # /api/v1/ping.json) can produce the same closure without
    # round-tripping through the factories. Returns nil for nil
    # request_id so legacy callers see no behavior change.
    def build_wire_logger(request_id)
      return nil unless request_id

      lambda do |direction, host, port, payload|
        Logger.debug(
          event: 'cgminer.wire',
          request_id: request_id,
          direction: direction,
          miner: "#{host}:#{port}",
          payload: payload
        )
      end
    end

    def miners_from(configured_miners, on_wire: nil)
      configured_miners.map do |host, port|
        CgminerApiClient::Miner.new(host, port, on_wire: on_wire)
      end
    end
    private_class_method :miners_from

    def miner_from_id(id, on_wire: nil)
      host, port = id.split(':', 2)
      CgminerApiClient::Miner.new(host, port.to_i, on_wire: on_wire)
    end
    private_class_method :miner_from_id
  end
end
