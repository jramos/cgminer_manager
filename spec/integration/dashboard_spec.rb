# frozen_string_literal: true

require 'rack/test'

RSpec.describe 'GET /', type: :integration do
  include Rack::Test::Methods

  def app = CgminerManager::HttpApp.new

  before do
    path = File.join(Dir.mktmpdir, 'miners.yml')
    File.write(path, "- host: 127.0.0.1\n  port: 4028\n")
    CgminerManager::HttpApp.configure_for_test!(
      monitor_url: 'http://localhost:9292', miners_file: path
    )
  end

  context 'when monitor is healthy' do
    before do
      stub_monitor_miners
      stub_monitor_summary(miner_id: '127.0.0.1:4028')
      stub_monitor_devices(miner_id: '127.0.0.1:4028')
      stub_monitor_pools(miner_id: '127.0.0.1:4028')
      stub_monitor_stats(miner_id: '127.0.0.1:4028')
    end

    it 'returns 200 and includes the miner row' do
      get '/'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include('127.0.0.1:4028')
    end

    it 'includes the CSRF meta tag in the rendered layout' do
      get '/'
      expect(last_response.body).to match(/<meta name="csrf-token" content="[^"]+">/)
    end
  end

  context 'when monitor is unreachable' do
    before do
      stub_request(:get, %r{localhost:9292/v2/.*}).to_raise(Errno::ECONNREFUSED)
    end

    it 'renders 200 with a "data source unavailable" banner (no 500)' do
      get '/'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include('data source unavailable')
    end
  end
end
