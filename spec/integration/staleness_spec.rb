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

  it 'renders a stale badge when fetched_at is older than threshold' do
    old_ts = (Time.now.utc - 3600).iso8601
    body = {
      miner: '127.0.0.1:4028', command: 'summary', ok: true,
      fetched_at: old_ts,
      response: { SUMMARY: [{ :'MHS 5s' => 100 }] }, error: nil # rubocop:disable Style/HashSyntax
    }.to_json
    stub_request(:get, %r{/v2/miners/127\.0\.0\.1.*/summary})
      .to_return(status: 200, body: body)

    get '/'
    expect(last_response.body).to match(/updated \d+m ago/i)
  end

  it 'renders a "waiting for first poll" placeholder when response is nil' do
    body = {
      miner: '127.0.0.1:4028', command: 'summary', ok: nil,
      fetched_at: nil, response: nil, error: nil
    }.to_json
    stub_request(:get, %r{/v2/miners/127\.0\.0\.1.*/summary})
      .to_return(status: 200, body: body)

    get '/'
    expect(last_response.body).to include('waiting for first poll')
  end
end
