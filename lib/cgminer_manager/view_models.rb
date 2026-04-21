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
  end
end
