# frozen_string_literal: true

RSpec.describe CgminerManager::MonitorClient do
  let(:url)    { 'http://localhost:9292' }
  let(:client) { described_class.new(base_url: url, timeout_ms: 2000) }
  let(:miner)  { '127.0.0.1:4028' }

  describe '#miners' do
    it 'returns the parsed miners array' do
      stub_monitor_miners
      result = client.miners
      expect(result[:miners]).to be_an(Array)
      expect(result[:miners].first[:id]).to eq('127.0.0.1:4028')
    end
  end

  describe '#summary' do
    it 'returns the snapshot hash for the miner' do
      stub_monitor_summary(miner_id: miner)
      result = client.summary(miner)
      expect(result[:ok]).to be true
      expect(result[:response][:SUMMARY].first[:'MHS 5s']).to eq(5123.45)
    end
  end

  describe '#devices' do
    it 'returns the devices snapshot' do
      stub_monitor_devices(miner_id: miner)
      expect(client.devices(miner)[:response][:DEVS]).to be_an(Array)
    end
  end

  describe '#pools' do
    it 'returns the pools snapshot' do
      stub_monitor_pools(miner_id: miner)
      expect(client.pools(miner)[:response][:POOLS].size).to eq(2)
    end
  end

  describe '#stats' do
    it 'returns the stats snapshot' do
      stub_monitor_stats(miner_id: miner)
      expect(client.stats(miner)[:response][:STATS]).to be_an(Array)
    end
  end

  describe '#graph_data' do
    it 'returns the {fields, data} envelope' do
      stub_monitor_graph(metric: 'hashrate', miner_id: miner, fixture: 'graph_data_hashrate.json')
      result = client.graph_data(metric: 'hashrate', miner_id: miner)
      expect(result[:fields]).to include('ts')
      expect(result[:data].first.size).to eq(7)
    end
  end

  describe '#healthz' do
    it 'returns the health payload' do
      stub_monitor_healthz
      expect(client.healthz[:status]).to eq('healthy')
    end
  end
end
