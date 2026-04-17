# frozen_string_literal: true

require 'rack/test'

RSpec.describe 'staleness surfacing on dashboard', type: :integration do
  include Rack::Test::Methods

  def app = CgminerManager::HttpApp.new

  before do
    path = File.join(Dir.mktmpdir, 'miners.yml')
    File.write(path, "- host: 127.0.0.1\n  port: 4028\n")
    CgminerManager::HttpApp.configure_for_test!(
      monitor_url: 'http://localhost:9292', miners_file: path,
      stale_threshold_seconds: 60
    )
    stub_monitor_miners
    stub_monitor_devices(miner_id: '127.0.0.1:4028')
    stub_monitor_pools(miner_id: '127.0.0.1:4028')
    stub_monitor_stats(miner_id: '127.0.0.1:4028')
  end

  # The rich dashboard (Phase C) replaced the per-row "updated Xm ago" badge
  # with the miner-hashrate/devices tables. Stale data now surfaces as empty
  # or zero cells in those tables rather than an explicit badge string; the
  # staleness helper itself is still covered by unit tests, and the banner
  # path is covered by dashboard_spec.rb.

  it 'still renders the dashboard 200 when summary fetched_at is ancient' do
    old_ts = (Time.now.utc - 3600).iso8601
    body = {
      miner: '127.0.0.1:4028', command: 'summary', ok: true,
      fetched_at: old_ts,
      response: { SUMMARY: [{ :'MHS 5s' => 100 }] }, error: nil # rubocop:disable Style/HashSyntax
    }.to_json
    stub_request(:get, %r{/v2/miners/127\.0\.0\.1.*/summary})
      .to_return(status: 200, body: body)

    get '/'
    expect(last_response.status).to eq(200)
    expect(last_response.body).to include('127.0.0.1:4028')
  end

  it 'still renders the dashboard 200 when summary has no response yet' do
    body = {
      miner: '127.0.0.1:4028', command: 'summary', ok: nil,
      fetched_at: nil, response: nil, error: nil
    }.to_json
    stub_request(:get, %r{/v2/miners/127\.0\.0\.1.*/summary})
      .to_return(status: 200, body: body)

    get '/'
    expect(last_response.status).to eq(200)
    expect(last_response.body).to include('127.0.0.1:4028')
  end
end
