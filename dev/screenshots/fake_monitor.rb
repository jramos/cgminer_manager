# frozen_string_literal: true

# Tiny stand-in for cgminer_monitor's /v2/* HTTP API. Serves deterministic
# responses synthesized from Scenario::MINERS so the manager dashboard can
# be screenshotted without physical miners.
#
# Run with: ruby dev/screenshots/fake_monitor.rb
# Binds 127.0.0.1:${PORT:-9292}.

require 'sinatra/base'
require 'json'
require_relative 'scenario'

class FakeMonitor < Sinatra::Base
  set :bind, ENV.fetch('BIND', '127.0.0.1')
  set :port, Integer(ENV.fetch('PORT', '9292'))
  set :environment, :production
  set :logging, false
  disable :show_exceptions, :raise_errors, :dump_errors

  before { content_type :json }

  get '/v2/healthz' do
    JSON.generate(ok: true)
  end

  get '/v2/miners' do
    JSON.generate(miners: Scenario::MINERS.map { |spec| miner_entry(spec) })
  end

  get '/v2/miners/:miner_id/summary' do |miner_id|
    spec = Scenario.find(miner_id) or halt 404
    JSON.generate(envelope(spec, 'summary', summary_response(spec)))
  end

  get '/v2/miners/:miner_id/devices' do |miner_id|
    spec = Scenario.find(miner_id) or halt 404
    JSON.generate(envelope(spec, 'devs', devices_response(spec)))
  end

  get '/v2/miners/:miner_id/pools' do |miner_id|
    spec = Scenario.find(miner_id) or halt 404
    JSON.generate(envelope(spec, 'pools', pools_response(spec)))
  end

  get '/v2/miners/:miner_id/stats' do |miner_id|
    spec = Scenario.find(miner_id) or halt 404
    JSON.generate(envelope(spec, 'stats', stats_response(spec)))
  end

  get '/v2/graph_data/:metric' do |metric|
    miner_id = params[:miner]
    rows = graph_rows(metric, miner_id)
    fields = graph_fields(metric, miner_id)
    halt(404, JSON.generate(error: "unknown metric: #{metric}")) if fields.nil?

    JSON.generate(
      metric: metric,
      miner: miner_id,
      since: (Scenario::NOW - Scenario::WINDOW_SECONDS).iso8601,
      until: Scenario::NOW.iso8601,
      fields: fields,
      data: rows
    )
  end

  helpers do
    def miner_entry(spec)
      {
        id: Scenario.miner_id(spec),
        host: spec[:host],
        port: spec[:port],
        available: true,
        last_poll: Scenario::NOW.iso8601
      }
    end

    def envelope(spec, command, response)
      {
        miner: Scenario.miner_id(spec),
        command: command,
        ok: true,
        fetched_at: Scenario::NOW.iso8601,
        response: response,
        error: nil
      }
    end

    def summary_response(spec)
      {
        'STATUS' => [{ 'STATUS' => 'S', 'When' => Scenario::NOW.to_i, 'Code' => 11, 'Msg' => 'Summary', 'Description' => 'cgminer 4.11.1' }],
        'SUMMARY' => [{
          'Elapsed' => spec[:elapsed],
          'GHS 5s' => spec[:ghs_5s],
          'GHS av' => spec[:ghs_av],
          'Found Blocks' => 0,
          'Getworks' => (spec[:elapsed] / 30.0).round,
          'Accepted' => Scenario.accepted_shares(spec),
          'Rejected' => Scenario.rejected_shares(spec),
          'Hardware Errors' => Scenario.hardware_errors(spec),
          'Utility' => (Scenario.accepted_shares(spec) * 60.0 / spec[:elapsed]).round(2),
          'Discarded' => (Scenario.accepted_shares(spec) * 0.1).round,
          'Stale' => 0,
          'Local Work' => (Scenario.accepted_shares(spec) * 1.5).round,
          'Network Blocks' => (spec[:elapsed] / 600.0).round,
          'Total MH' => (spec[:ghs_av] * spec[:elapsed] * 1000).round,
          'Work Utility' => (spec[:ghs_av] * 14.3).round(2),
          'Difficulty Accepted' => Scenario.accepted_shares(spec) * 1.0,
          'Difficulty Rejected' => Scenario.rejected_shares(spec) * 1.0,
          'Best Share' => 1_048_576 + (spec[:elapsed] * 13 % 500_000),
          'Last getwork' => Scenario::NOW.to_i - 7
        }]
      }
    end

    def devices_response(spec)
      main = chain_device(spec, 0, "#{spec[:chain_prefix]}", spec[:ghs_5s], spec[:ghs_av])
      { 'STATUS' => ok_status('Devs'), 'DEVS' => [main] }
    end

    def chain_device(spec, id, name, ghs_5s, ghs_av)
      {
        'ASC' => id,
        'Name' => name,
        'ID' => id,
        'Enabled' => 'Y',
        'Status' => 'Alive',
        'Temperature' => spec[:temp],
        'MHS 5s' => ghs_5s * 1000.0,
        'MHS av' => ghs_av * 1000.0,
        'Accepted' => Scenario.accepted_shares(spec),
        'Rejected' => Scenario.rejected_shares(spec),
        'Hardware Errors' => Scenario.hardware_errors(spec),
        'Utility' => (Scenario.accepted_shares(spec) * 60.0 / spec[:elapsed]).round(2),
        'Last Share Pool' => 0,
        'Last Share Time' => Scenario::NOW.to_i - 2,
        'Total MH' => (ghs_av * spec[:elapsed] * 1000).round,
        'Diff1 Work' => Scenario.accepted_shares(spec) + Scenario.rejected_shares(spec),
        'Difficulty Accepted' => Scenario.accepted_shares(spec) * 1.0,
        'Difficulty Rejected' => Scenario.rejected_shares(spec) * 1.0,
        'Last Share Difficulty' => 1.0,
        'Device Elapsed' => spec[:elapsed],
        'Device Hardware%' => spec[:hw_err_pct],
        'Device Rejected%' => spec[:rejected_pct]
      }
    end

    def pools_response(spec)
      worker = Scenario.worker_name(spec)
      pools = [
        pool_entry(spec, 0, Scenario::POOL_PRIMARY, worker, 0, 'Alive'),
        pool_entry(spec, 1, Scenario::POOL_SECONDARY, worker, 1, 'Alive')
      ]
      { 'STATUS' => ok_status('Pools'), 'POOLS' => pools }
    end

    def pool_entry(spec, id, url, user, priority, status)
      active = priority.zero? ? Scenario.accepted_shares(spec) : 0
      rej = priority.zero? ? Scenario.rejected_shares(spec) : 0
      {
        'POOL' => id,
        'URL' => url,
        'Status' => status,
        'Priority' => priority,
        'Quota' => 1,
        'Long Poll' => 'N',
        'Getworks' => (spec[:elapsed] / (priority.zero? ? 30.0 : 120.0)).round,
        'Accepted' => active,
        'Rejected' => rej,
        'Works' => active + rej,
        'Discarded' => (active * 0.1).round,
        'Stale' => 0,
        'Get Failures' => 0,
        'Remote Failures' => 0,
        'User' => user,
        'Last Share Time' => priority.zero? ? (Scenario::NOW.to_i - 3) : 0,
        'Diff1 Shares' => active + rej,
        'Difficulty Accepted' => active * 1.0,
        'Difficulty Rejected' => rej * 1.0,
        'Difficulty Stale' => 0.0,
        'Last Share Difficulty' => 1.0,
        'Has Stratum' => true,
        'Stratum Active' => priority.zero?,
        'Stratum URL' => url.sub('stratum+tcp://', ''),
        'Has GBT' => false,
        'Best Share' => 1_048_576,
        'Pool Rejected%' => priority.zero? ? spec[:rejected_pct] : 0.0,
        'Pool Stale%' => 0.0
      }
    end

    def stats_response(spec)
      entry = {
        'STATS' => 0,
        'ID' => "#{spec[:chain_prefix]}0",
        'Elapsed' => spec[:elapsed],
        'Calls' => (spec[:elapsed] / 5.0).round,
        'Wait' => 0.0,
        'Max' => 0.0,
        'Min' => 0.0,
        'chain_acs1' => Scenario::CHAIN_STATUS,
        'chain_acs2' => Scenario::CHAIN_STATUS,
        'temp1' => spec[:temp],
        'temp2' => spec[:temp] - 0.5,
        'fan1' => 6000,
        'fan2' => 6000,
        'GHS 5s' => spec[:ghs_5s].to_s,
        'GHS av' => spec[:ghs_av]
      }
      { 'STATUS' => ok_status('Stats'), 'STATS' => [entry] }
    end

    def ok_status(msg)
      [{ 'STATUS' => 'S', 'When' => Scenario::NOW.to_i, 'Code' => 70, 'Msg' => msg, 'Description' => 'cgminer 4.11.1' }]
    end

    def graph_fields(metric, miner_id)
      case metric
      when 'hashrate'     then %w[ts ghs_5s ghs_av device_hardware_pct device_rejected_pct pool_rejected_pct pool_stale_pct]
      when 'temperature'  then %w[ts min avg max]
      when 'availability' then miner_id ? %w[ts available] : %w[ts available configured]
      end
    end

    def graph_rows(metric, miner_id)
      specs = miner_id ? [Scenario.find(miner_id)].compact : Scenario::MINERS
      return [] if specs.empty?

      Scenario.timestamps.each_with_index.map do |ts, i|
        case metric
        when 'hashrate'     then hashrate_row(specs, ts, i, miner_id)
        when 'temperature'  then temperature_row(specs, ts, i, miner_id)
        when 'availability' then availability_row(specs, ts, miner_id)
        else []
        end
      end
    end

    def hashrate_row(specs, ts, idx, miner_id)
      rng = prng('hashrate', miner_id, idx)
      ghs_5s = specs.sum { |s| jitter(s[:ghs_5s], 0.03, rng) }
      ghs_av = specs.sum { |s| jitter(s[:ghs_av], 0.015, rng) }
      hw_pct   = weighted_mean(specs, :hw_err_pct,  :ghs_av, rng, 0.2)
      dev_rej  = weighted_mean(specs, :rejected_pct, :ghs_av, rng, 0.05)
      pool_rej = weighted_mean(specs, :rejected_pct, :ghs_av, rng, 0.04)
      pool_stl = jitter(0.002, 0.3, rng)
      [ts, round2(ghs_5s), round2(ghs_av), round4(hw_pct), round4(dev_rej),
       round4(pool_rej), round4(pool_stl)]
    end

    def temperature_row(specs, ts, idx, miner_id)
      rng = prng('temperature', miner_id, idx)
      if specs.size == 1
        # Per-miner reading: fabricate a plausible min/avg/max spread across
        # the miner's chips so the legacy three-band chart still renders.
        avg = jitter(specs.first[:temp], 0.02, rng)
        [ts, round1(avg - jitter(2.5, 0.3, rng)), round1(avg), round1(avg + jitter(3.0, 0.3, rng))]
      else
        temps = specs.map { |s| jitter(s[:temp], 0.02, rng) }
        [ts, round1(temps.min), round1(temps.sum / temps.size), round1(temps.max)]
      end
    end

    def availability_row(specs, ts, miner_id)
      if miner_id
        [ts, 1]
      else
        [ts, specs.size, Scenario::MINERS.size]
      end
    end

    def prng(metric, miner_id, idx)
      Random.new(42 ^ metric.hash ^ (miner_id || 'aggregate').hash ^ idx)
    end

    def jitter(value, pct, rng)
      value + (value * pct * (rng.rand - 0.5) * 2)
    end

    def weighted_mean(specs, field, weight, rng, jitter_pct)
      total_weight = specs.sum { |s| s[weight] }
      return 0.0 if total_weight.zero?

      mean = specs.sum { |s| s[field] * s[weight] } / total_weight
      jitter(mean, jitter_pct, rng).clamp(0.0, 100.0)
    end

    def round1(num) = num.to_f.round(1)
    def round2(num) = num.to_f.round(2)
    def round4(num) = num.to_f.round(4)
  end

  run! if __FILE__ == $PROGRAM_NAME
end
