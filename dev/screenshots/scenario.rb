# frozen_string_literal: true

# Source-of-truth scenario for the screenshot harness: 6 cgminers
# (2 Antminer S3 + 4 Antminer S1) producing realistic per-endpoint data
# and 60-minute graph time-series ending at the fixed anchor time.
#
# Values reconstructed from public/screenshots/miner-pool.png in the
# v0-legacy tag (captured 2014-08-09).
#
# Each miner is identified in the monitor (and routed by the manager)
# using host:port = 127.0.0.1:4028N. The `label` field is what the UI
# renders in place of host:port — that reproduces the legacy
# 192.168.1.15X:4028 look in screenshots while the backend talks to
# real FakeCgminer listeners on localhost.
module Scenario
  NOW = Time.utc(2026, 4, 17, 9, 4, 6)
  WINDOW_SECONDS = 60 * 60
  SAMPLE_INTERVAL = 60
  CHAIN_STATUS = 'oooooooo oooooooo oooooooo oooooooo'

  MINERS = [
    { host: '127.0.0.1', port: 40281, label: '192.168.1.151:4028',
      model: :s3, chain_prefix: 'BMM',
      ghs_5s: 491.99, ghs_av: 478.65, temp: 45.0, rejected_pct: 1.95, hw_err_pct: 0.0, elapsed: 16 * 3600 },
    { host: '127.0.0.1', port: 40282, label: '192.168.1.152:4028',
      model: :s3, chain_prefix: 'BMM',
      ghs_5s: 487.96, ghs_av: 478.11, temp: 45.0, rejected_pct: 1.81, hw_err_pct: 0.0, elapsed: 16 * 3600 },
    { host: '127.0.0.1', port: 40283, label: '192.168.1.153:4028',
      model: :s1, chain_prefix: 'ANT',
      ghs_5s: 207.64, ghs_av: 201.13, temp: 52.0, rejected_pct: 2.46, hw_err_pct: 0.32, elapsed: 6 * 3600 },
    { host: '127.0.0.1', port: 40284, label: '192.168.1.154:4028',
      model: :s1, chain_prefix: 'ANT',
      ghs_5s: 204.40, ghs_av: 200.09, temp: 51.5, rejected_pct: 3.55, hw_err_pct: 0.57, elapsed: 16 * 3600 },
    { host: '127.0.0.1', port: 40285, label: '192.168.1.155:4028',
      model: :s1, chain_prefix: 'ANT',
      ghs_5s: 197.49, ghs_av: 200.62, temp: 50.0, rejected_pct: 3.12, hw_err_pct: 0.34, elapsed: 14 * 3600 },
    { host: '127.0.0.1', port: 40286, label: '192.168.1.156:4028',
      model: :s1, chain_prefix: 'ANT',
      ghs_5s: 205.71, ghs_av: 200.37, temp: 51.5, rejected_pct: 3.13, hw_err_pct: 0.61, elapsed: 14 * 3600 }
  ].freeze

  POOL_PRIMARY   = 'stratum+tcp://stratum.slushpool.com:3333'
  POOL_SECONDARY = 'stratum+tcp://us-east.stratum.slushpool.com:3333'

  def self.miner_id(spec)
    "#{spec[:host]}:#{spec[:port]}"
  end

  def self.find(miner_id)
    MINERS.find { |m| miner_id(m) == miner_id }
  end

  def self.worker_name(spec)
    octet = spec[:label].split('.').last.split(':').first
    "jramos.rig#{octet}"
  end

  def self.accepted_shares(spec)
    # Rough: work_per_second * elapsed; keeps Rejected/Accepted ratio honest.
    base = (spec[:ghs_av] * spec[:elapsed] / 60.0).round
    [base, 100].max
  end

  def self.rejected_shares(spec)
    (accepted_shares(spec) * spec[:rejected_pct] / 100.0).round
  end

  def self.hardware_errors(spec)
    return 0 if spec[:hw_err_pct].zero?

    (accepted_shares(spec) * spec[:hw_err_pct] / 100.0).round
  end

  def self.timestamps
    anchor = NOW.to_i
    (anchor - WINDOW_SECONDS + SAMPLE_INTERVAL..anchor).step(SAMPLE_INTERVAL).to_a
  end
end
