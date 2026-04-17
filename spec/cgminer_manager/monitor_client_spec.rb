# frozen_string_literal: true

require 'stringio'

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

  describe '#graph_data without miner_id' do
    it 'omits the miner query param' do
      stub_request(:get, 'http://localhost:9292/v2/graph_data/hashrate')
        .to_return(status: 200, body: '{"fields":["ts","ghs_5s"],"data":[]}',
                   headers: { 'Content-Type' => 'application/json' })

      client.graph_data(metric: 'hashrate')

      expect(a_request(:get, 'http://localhost:9292/v2/graph_data/hashrate')
               .with { |req| !req.uri.query.to_s.include?('miner=') }).to have_been_made
    end
  end

  describe '#healthz' do
    it 'returns the health payload' do
      stub_monitor_healthz
      expect(client.healthz[:status]).to eq('healthy')
    end
  end
end

RSpec.describe CgminerManager::MonitorClient do
  let(:url)    { 'http://localhost:9292' }
  let(:client) { described_class.new(base_url: url, timeout_ms: 2000) }

  describe 'error handling' do
    it 'raises MonitorError::ApiError on 5xx' do
      stub_monitor_miners(status: 503)
      expect { client.miners }.to raise_error(CgminerManager::MonitorError::ApiError)
    end

    it 'attaches status and body on ApiError' do
      stub_monitor_miners(status: 500)
      client.miners
    rescue CgminerManager::MonitorError::ApiError => e
      expect(e.status).to eq(500)
      expect(e.body).not_to be_nil
    end

    it 'raises MonitorError::ConnectionError on connection refused' do
      stub_request(:get, "#{url}/v2/miners").to_raise(Errno::ECONNREFUSED)
      expect { client.miners }.to raise_error(CgminerManager::MonitorError::ConnectionError)
    end

    it 'raises MonitorError::ConnectionError on timeout' do
      stub_request(:get, "#{url}/v2/miners").to_timeout
      expect { client.miners }.to raise_error(CgminerManager::MonitorError::ConnectionError)
    end
  end

  describe 'observability' do
    it 'emits a monitor.call log line per request' do
      stub_monitor_miners
      logged = capture_logger_output { client.miners }
      expect(logged).to include('monitor.call')
    end
  end

  def capture_logger_output
    io = StringIO.new
    original = CgminerManager::Logger.output
    CgminerManager::Logger.output = io
    yield
    io.string
  ensure
    CgminerManager::Logger.output = original
  end
end
