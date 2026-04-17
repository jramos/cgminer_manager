# frozen_string_literal: true

require 'rack/test'

RSpec.describe 'rich per-miner page rendering', type: :integration do
  include Rack::Test::Methods

  def app = CgminerManager::HttpApp.new

  let(:miner_id) { '127.0.0.1:4028' }

  before do
    path = File.join(Dir.mktmpdir, 'miners.yml')
    File.write(path, "- host: 127.0.0.1\n  port: 4028\n")
    CgminerManager::HttpApp.configure_for_test!(
      monitor_url: 'http://localhost:9292', miners_file: path
    )
    stub_monitor_miners
    stub_monitor_summary(miner_id: miner_id)
    stub_monitor_devices(miner_id: miner_id)
    stub_monitor_pools(miner_id: miner_id)
    stub_monitor_stats(miner_id: miner_id)
  end

  it 'renders all 4 tab anchors (no admin tab)' do
    get "/miner/#{CGI.escape(miner_id)}"
    expect(last_response.body).to include('href="#summary"')
    expect(last_response.body).to include('href="#devices"')
    expect(last_response.body).to include('href="#pools"')
    expect(last_response.body).to include('href="#stats"')
    expect(last_response.body).not_to include('href="#admin"')
  end

  it 'renders the per-miner hashrate graph canvas' do
    get "/miner/#{CGI.escape(miner_id)}"
    # The shared _hashrate.haml partial uses id="local_hashrate" for both
    # dashboard (target='local') and per-miner (target='miner').
    expect(last_response.body).to match(/id=['"]local_hashrate['"]/)
  end

  it 'renders summary values from the snapshot via number_with_delimiter' do
    get "/miner/#{CGI.escape(miner_id)}"
    # The summary fixture has Accepted: 100 — after number_with_delimiter
    # and the surrounding table structure it should appear as '100' in the body.
    expect(last_response.body).to include('100')
  end
end
