# frozen_string_literal: true

module CgminerManager
  # Stand-in for the legacy CgminerApiClient::Miner instance passed into
  # rich partials. Implements the .host / .port / .available? / .to_s
  # surface the partials need (verified via grep of legacy _miner_pool.haml
  # and its descendants).
  #
  # Data.define is chosen for value-equality semantics: _warnings.haml
  # calls `@bad_chain_elements.uniq!`, which relies on == working by field.
  # Always coerce port to Integer (miners.yml may load as String).
  ViewMiner = Data.define(:host, :port, :available) do
    def self.build(host, port, available)
      new(host: host.to_s, port: Integer(port), available: available)
    end

    def available? = available
    def to_s       = "#{host}:#{port}"
  end

  ViewMinerPool = Data.define(:miners) do
    def available_miners   = miners.select(&:available?)
    def unavailable_miners = miners.reject(&:available?)
  end
end
