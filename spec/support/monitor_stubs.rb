# frozen_string_literal: true

require 'cgi'
require 'webmock/rspec'
require 'json'

module MonitorStubs
  FIXTURES_DIR = File.expand_path('../fixtures/monitor', __dir__)
  DEFAULT_URL  = 'http://localhost:9292'

  def stub_monitor_miners(fixture: 'miners.json', url: DEFAULT_URL, status: 200)
    body = File.read(File.join(FIXTURES_DIR, fixture))
    stub_request(:get, "#{url}/v2/miners").to_return(status: status, body: body,
                                                     headers: { 'Content-Type' => 'application/json' })
  end

  def stub_monitor_summary(miner_id:, fixture: 'summary.json', url: DEFAULT_URL, status: 200)
    body = File.read(File.join(FIXTURES_DIR, fixture))
    stub_request(:get, "#{url}/v2/miners/#{CGI.escape(miner_id)}/summary")
      .to_return(status: status, body: body, headers: { 'Content-Type' => 'application/json' })
  end

  def stub_monitor_devices(miner_id:, fixture: 'devices.json', url: DEFAULT_URL, status: 200)
    body = File.read(File.join(FIXTURES_DIR, fixture))
    stub_request(:get, "#{url}/v2/miners/#{CGI.escape(miner_id)}/devices")
      .to_return(status: status, body: body, headers: { 'Content-Type' => 'application/json' })
  end

  def stub_monitor_pools(miner_id:, fixture: 'pools.json', url: DEFAULT_URL, status: 200)
    body = File.read(File.join(FIXTURES_DIR, fixture))
    stub_request(:get, "#{url}/v2/miners/#{CGI.escape(miner_id)}/pools")
      .to_return(status: status, body: body, headers: { 'Content-Type' => 'application/json' })
  end

  def stub_monitor_stats(miner_id:, fixture: 'stats.json', url: DEFAULT_URL, status: 200)
    body = File.read(File.join(FIXTURES_DIR, fixture))
    stub_request(:get, "#{url}/v2/miners/#{CGI.escape(miner_id)}/stats")
      .to_return(status: status, body: body, headers: { 'Content-Type' => 'application/json' })
  end

  def stub_monitor_graph(metric:, miner_id:, fixture:, url: DEFAULT_URL, status: 200)
    body = File.read(File.join(FIXTURES_DIR, fixture))
    stub_request(:get, "#{url}/v2/graph_data/#{metric}")
      .with(query: hash_including('miner' => miner_id))
      .to_return(status: status, body: body, headers: { 'Content-Type' => 'application/json' })
  end

  def stub_monitor_healthz(url: DEFAULT_URL, status: 200, fixture: 'healthz.json')
    body = File.read(File.join(FIXTURES_DIR, fixture))
    stub_request(:get, "#{url}/v2/healthz")
      .to_return(status: status, body: body, headers: { 'Content-Type' => 'application/json' })
  end
end

RSpec.configure do |config|
  config.include MonitorStubs
  config.before { WebMock.reset! }
end
