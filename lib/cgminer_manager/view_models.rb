# frozen_string_literal: true

module CgminerManager
  # Pure functions that turn MonitorClient results + configured_miners
  # tuples into dashboard-ready hashes. No Sinatra, no request context —
  # HttpApp threads settings / configured_miners / a MonitorClient in
  # explicitly. This lets specs exercise view-model logic without
  # Rack::Test.
  module ViewModels
    module_function

    def build_view_miner_pool(monitor_miners, configured_miners:)
      labels_by_id = configured_labels_by_id(configured_miners)
      view_miners = (monitor_miners || []).map do |m|
        build_view_miner_from_monitor(m, labels_by_id)
      end
      ViewMinerPool.new(miners: view_miners)
    end

    def configured_labels_by_id(configured_miners)
      configured_miners.each_with_object({}) do |(host, port, label), acc|
        acc["#{host}:#{port}"] = label
      end
    end

    def build_view_miner_from_monitor(raw, labels_by_id)
      host  = raw[:host] || raw['host']
      port  = raw[:port] || raw['port']
      avail = raw.fetch(:available) { raw['available'] || false }
      ViewMiner.build(host, port, avail, labels_by_id["#{host}:#{port}"])
    end

    def build_dashboard(monitor_client:, configured_miners:, stale_threshold_seconds:, pool_thread_cap:)
      begin
        miners = monitor_client.miners[:miners]
      rescue MonitorError => e
        fallback = configured_miners.map do |host, port, _label|
          { id: "#{host}:#{port}", host: host, port: port }
        end
        return { miners: fallback, snapshots: {},
                 banner: "data source unavailable (#{e.message})",
                 stale_threshold: stale_threshold_seconds }
      end
      snapshots = fetch_snapshots_for(monitor_client, miners, pool_thread_cap)
      { miners: miners, snapshots: snapshots, banner: nil,
        stale_threshold: stale_threshold_seconds }
    end

    def fetch_snapshots_for(monitor_client, miners, pool_thread_cap)
      # `|| 1` stays at the call site so ThreadedFanOut.map can stay
      # strict (raises on nil cap).
      pairs = ThreadedFanOut.map(miners, thread_cap: pool_thread_cap || 1) do |miner|
        id = miner[:id] || miner['id']
        [id, fetch_tile(monitor_client, id)]
      end
      pairs.to_h
    end

    def fetch_tile(monitor_client, miner_id)
      {
        summary: safe_fetch { monitor_client.summary(miner_id) },
        devices: safe_fetch { monitor_client.devices(miner_id) },
        pools: safe_fetch { monitor_client.pools(miner_id) },
        stats: safe_fetch { monitor_client.stats(miner_id) }
      }
    end

    def safe_fetch
      yield
    rescue MonitorError => e
      { error: e.message }
    end

    def build_miner_view_model(miner_id:, monitor_client:)
      {
        miner_id: miner_id,
        snapshots: {
          summary: safe_fetch { monitor_client.summary(miner_id) },
          devices: safe_fetch { monitor_client.devices(miner_id) },
          pools: safe_fetch { monitor_client.pools(miner_id) },
          stats: safe_fetch { monitor_client.stats(miner_id) }
        }
      }
    end

    def build_view_miner_pool_from_yml(configured_miners:)
      view_miners = configured_miners.map do |host, port, label|
        ViewMiner.build(host, port, false, label)
      end
      ViewMinerPool.new(miners: view_miners)
    end

    # Returns the bare neighbor IDs. URL construction is a Sinatra
    # helper concern; the delegating wrapper on HttpApp maps each id
    # through miner_url(id) after the fact.
    def neighbor_ids(miner_id, configured_miners:)
      ids = configured_miners.map { |host, port| "#{host}:#{port}" }
      idx = ids.index(miner_id)
      prev_id = idx&.positive? ? ids[idx - 1] : nil
      next_id = idx && idx < ids.size - 1 ? ids[idx + 1] : nil
      [prev_id, next_id]
    end

    def miner_configured?(miner_id, configured_miners:)
      configured_miners.any? { |host, port| "#{host}:#{port}" == miner_id }
    end
  end
end
