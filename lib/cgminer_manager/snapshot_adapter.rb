# frozen_string_literal: true

module CgminerManager
  # Translates monitor's /v2/miners/:id/:type responses into the nested
  # shape the legacy Rails partials expect (@miner_data[i][type].first[type]).
  #
  # The inner cgminer response preserves raw cgminer keys ("MHS 5s",
  # "Device Hardware%", "Temperature"). Legacy partials read the sanitized
  # symbolic form (:mhs_5s, :'device_hardware%', :temperature) — matching
  # cgminer_api_client's Miner#sanitized transform (not monitor's Poller
  # %-to-_pct normalization, which applies only to time-series Samples).
  module SnapshotAdapter
    def self.sanitize(node)
      case node
      when Hash  then node.each_with_object({}) { |(k, v), h| h[sanitize_key(k)] = sanitize(v) }
      when Array then node.map { |v| sanitize(v) }
      else node
      end
    end

    def self.sanitize_key(key)
      key.to_s.downcase.tr(' ', '_').to_sym
    end

    def self.legacy_shape(snapshot, type)
      return nil if snapshot.nil? || snapshot[:error] || snapshot[:response].nil?

      resp = sanitize(snapshot[:response])
      inner_key = type.to_s.downcase.to_sym
      [{ type => resp[inner_key] || [] }]
    end

    def self.build_miner_data(configured_miners, snapshots)
      configured_miners.map do |(host, port)|
        miner_id = "#{host}:#{port}"
        tile = snapshots[miner_id] || {}
        {
          summary: legacy_shape(tile[:summary], :summary),
          devs: legacy_shape(tile[:devices], :devs),
          pools: legacy_shape(tile[:pools], :pools),
          stats: legacy_shape(tile[:stats], :stats)
        }
      end
    end
  end
end
