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
  ViewMiner = Data.define(:host, :port, :available, :label) do
    def self.build(host, port, available, label = nil)
      normalized_label = label.nil? || label.to_s.empty? ? nil : label.to_s
      new(host: host.to_s, port: Integer(port), available: available, label: normalized_label)
    end

    def available?    = available
    def host_port     = "#{host}:#{port}"
    def display_label = label || host_port
    def to_s          = display_label
  end

  ViewMinerPool = Data.define(:miners) do
    def available_miners   = miners.select(&:available?)
    def unavailable_miners = miners.reject(&:available?)
  end
end
