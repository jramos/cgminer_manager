# frozen_string_literal: true

require 'rack/test'

RSpec.describe 'GET /healthz', type: :integration do
  include Rack::Test::Methods

  def app = CgminerManager::HttpApp.new

  before do
    CgminerManager::HttpApp.configure_for_test!(
      monitor_url: 'http://localhost:9292',
      miners_file: write_miners_file
    )
  end

  def write_miners_file
    path = File.join(Dir.mktmpdir, 'miners.yml')
    File.write(path, "- host: 127.0.0.1\n  port: 4028\n")
    path
  end

  context 'when monitor is healthy' do
    it 'returns 200 {ok: true}' do
      stub_monitor_healthz(status: 200)
      get '/healthz'
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body, symbolize_names: true)
      expect(body[:ok]).to be true
    end
  end

  context 'when monitor is unreachable' do
    it 'returns 503 {ok: false, reasons: [...]}' do
      stub_request(:get, 'http://localhost:9292/v2/healthz').to_raise(Errno::ECONNREFUSED)
      get '/healthz'
      expect(last_response.status).to eq(503)
      body = JSON.parse(last_response.body, symbolize_names: true)
      expect(body[:ok]).to be false
      expect(body[:reasons]).to include(match(/monitor/))
    end
  end

  context 'when miners.yml is unparseable' do
    it 'returns 503' do
      path = File.join(Dir.mktmpdir, 'miners.yml')
      File.write(path, 'not: valid: yaml: colons')
      CgminerManager::HttpApp.configure_for_test!(
        monitor_url: 'http://localhost:9292', miners_file: path
      )
      stub_monitor_healthz
      get '/healthz'
      expect(last_response.status).to eq(503)
    end
  end
end
