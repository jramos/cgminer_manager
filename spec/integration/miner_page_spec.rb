# frozen_string_literal: true

require 'rack/test'

RSpec.describe 'GET /miner/:miner_id', type: :integration do
  include Rack::Test::Methods

  def app = CgminerManager::HttpApp.new

  before do
    path = File.join(Dir.mktmpdir, 'miners.yml')
    File.write(path, "- host: 127.0.0.1\n  port: 4028\n")
    CgminerManager::HttpApp.configure_for_test!(
      monitor_url: 'http://localhost:9292', miners_file: path
    )
    stub_monitor_miners
    stub_monitor_summary(miner_id: '127.0.0.1:4028')
    stub_monitor_devices(miner_id: '127.0.0.1:4028')
    stub_monitor_pools(miner_id: '127.0.0.1:4028')
    stub_monitor_stats(miner_id: '127.0.0.1:4028')
  end

  it 'renders the miner detail page (URL-encoded host:port)' do
    get "/miner/#{CGI.escape('127.0.0.1:4028')}"
    expect(last_response.status).to eq(200)
    expect(last_response.body).to include('127.0.0.1:4028')
  end

  it 'returns 404 when miner is not in miners.yml' do
    get "/miner/#{CGI.escape('99.99.99.99:4028')}"
    expect(last_response.status).to eq(404)
  end

  it 'renders the 4 miner tabs (Miner/Devs/Pools/Stats, no Admin)' do
    get "/miner/#{CGI.escape('127.0.0.1:4028')}"
    expect(last_response.body).to include('href="#summary"')
    expect(last_response.body).to include('href="#devices"')
    expect(last_response.body).to include('href="#pools"')
    expect(last_response.body).to include('href="#stats"')
    expect(last_response.body).not_to include('href="#admin"')
  end

  it 'renders per-miner graph canvases' do
    get "/miner/#{CGI.escape('127.0.0.1:4028')}"
    expect(last_response.body).to match(/<canvas[^>]+id=['"]local_hashrate['"]/)
    expect(last_response.body).to match(/<canvas[^>]+id=['"]local_availability['"]/)
  end
end
