# frozen_string_literal: true

require 'spec_helper'

# Pure unit specs for the view-model builders extracted out of HttpApp.
# No Rack::Test, no Sinatra boot — the whole point of the extraction is
# that these functions only depend on their kwargs.
RSpec.describe CgminerManager::ViewModels do
  let(:configured_miners) do
    [
      ['10.0.0.1', 4028, 'rig-a'],
      ['10.0.0.2', 4028, nil]
    ].freeze
  end

  describe '.build_view_miner_pool' do
    it 'threads labels through from configured_miners into each ViewMiner' do
      monitor_miners = [
        { id: '10.0.0.1:4028', host: '10.0.0.1', port: 4028, available: true },
        { id: '10.0.0.2:4028', host: '10.0.0.2', port: 4028, available: false }
      ]
      pool = described_class.build_view_miner_pool(monitor_miners, configured_miners: configured_miners)

      expect(pool.miners.length).to eq(2)
      expect(pool.miners.first.label).to eq('rig-a')
      expect(pool.miners.first.available).to be(true)
      expect(pool.miners.last.label).to be_nil
      expect(pool.miners.last.available).to be(false)
    end

    it 'returns an empty pool for a nil monitor result' do
      pool = described_class.build_view_miner_pool(nil, configured_miners: configured_miners)
      expect(pool.miners).to be_empty
    end
  end

  describe '.build_dashboard' do
    let(:monitor_client) { instance_double(CgminerManager::MonitorClient) }

    it 'returns miners + snapshots when monitor is reachable' do
      allow(monitor_client).to receive_messages(
        miners: { miners: [{ id: '10.0.0.1:4028', host: '10.0.0.1', port: 4028, available: true }] },
        summary: { ghs_5s: 1234 },
        devices: [],
        pools: [],
        stats: {}
      )

      result = described_class.build_dashboard(
        monitor_client: monitor_client,
        configured_miners: configured_miners,
        stale_threshold_seconds: 300,
        pool_thread_cap: 8
      )
      expect(result[:miners].length).to eq(1)
      expect(result[:snapshots]['10.0.0.1:4028']).to include(:summary, :devices, :pools, :stats)
      expect(result[:banner]).to be_nil
      expect(result[:stale_threshold]).to eq(300)
    end

    it 'falls back to configured_miners with a banner when monitor raises MonitorError' do
      allow(monitor_client).to receive(:miners).and_raise(CgminerManager::MonitorError, 'connect refused')

      result = described_class.build_dashboard(
        monitor_client: monitor_client,
        configured_miners: configured_miners,
        stale_threshold_seconds: 300,
        pool_thread_cap: 8
      )
      expect(result[:miners].length).to eq(2)
      expect(result[:miners].first).to include(id: '10.0.0.1:4028', host: '10.0.0.1', port: 4028)
      expect(result[:banner]).to include('connect refused')
      expect(result[:snapshots]).to eq({})
    end
  end

  describe '.build_miner_view_model' do
    let(:monitor_client) { instance_double(CgminerManager::MonitorClient) }

    it 'returns a snapshot hash keyed by command' do
      allow(monitor_client).to receive_messages(
        summary: { ghs_5s: 1 }, devices: [], pools: [], stats: {}
      )
      vm = described_class.build_miner_view_model(
        miner_id: '10.0.0.1:4028', monitor_client: monitor_client
      )
      expect(vm[:miner_id]).to eq('10.0.0.1:4028')
      expect(vm[:snapshots][:summary]).to eq({ ghs_5s: 1 })
    end

    it 'captures per-command errors via safe_fetch' do
      allow(monitor_client).to receive(:summary).and_raise(CgminerManager::MonitorError, 'timeout')
      allow(monitor_client).to receive_messages(devices: [], pools: [], stats: {})
      vm = described_class.build_miner_view_model(
        miner_id: '10.0.0.1:4028', monitor_client: monitor_client
      )
      expect(vm[:snapshots][:summary]).to eq({ error: 'timeout' })
    end
  end

  describe '.build_view_miner_pool_from_yml' do
    it 'builds a ViewMinerPool with availability defaulted to false' do
      pool = described_class.build_view_miner_pool_from_yml(configured_miners: configured_miners)
      expect(pool.miners.length).to eq(2)
      expect(pool.miners).to all(have_attributes(available: false))
      expect(pool.miners.first.label).to eq('rig-a')
    end
  end

  describe '.neighbor_ids' do
    it 'returns prev/next IDs for a middle miner' do
      cm = [['a', 1, nil], ['b', 2, nil], ['c', 3, nil]].freeze
      prev_id, next_id = described_class.neighbor_ids('b:2', configured_miners: cm)
      expect(prev_id).to eq('a:1')
      expect(next_id).to eq('c:3')
    end

    it 'returns nil for prev at first and nil for next at last' do
      cm = [['a', 1, nil], ['b', 2, nil]].freeze
      prev_id, next_id = described_class.neighbor_ids('a:1', configured_miners: cm)
      expect(prev_id).to be_nil
      expect(next_id).to eq('b:2')
    end
  end

  describe '.miner_configured?' do
    it 'returns true when the miner id is in configured_miners' do
      expect(described_class.miner_configured?('10.0.0.1:4028', configured_miners: configured_miners)).to be(true)
    end

    it 'returns false otherwise' do
      expect(described_class.miner_configured?('1.2.3.4:9', configured_miners: configured_miners)).to be(false)
    end
  end
end
