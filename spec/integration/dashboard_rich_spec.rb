# frozen_string_literal: true

require 'rack/test'

RSpec.describe 'rich dashboard rendering', type: :integration do
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

  it 'renders the 6 dashboard graph canvases' do
    get '/'
    body = last_response.body
    # All six canvas IDs on one page (hashrate, temperature, and the 4 error rates);
    # combined into a single array assertion to stay within expectation count.
    # HAML emits single-quoted attrs, so match either quote style.
    ids = %w[
      local_hashrate
      hardware_error_hashrate
      device_rejected_hashrate
      pool_rejected_hashrate
      pool_stale_hashrate
      local_temperature
    ]
    missing = ids.reject { |id| body.match?(/id=['"]#{Regexp.escape(id)}['"]/) }
    expect(missing).to be_empty
  end

  it 'renders the miner hashrate + devices tables per miner' do
    get '/'
    # _miner_hashrate_table produces 'Rate(5s)' / 'Rate(avg)' headers;
    # the miner host:port appears in the row.
    expect(last_response.body).to include('Rate(5s)')
    expect(last_response.body).to include('Rate(avg)')
    expect(last_response.body).to include('127.0.0.1')
  end

  it 'uses the new Sinatra /graph_data URL in the embedded JS' do
    get '/'
    expect(last_response.body).to include('/graph_data/hashrate')
    expect(last_response.body).not_to include('/cgminer_monitor/api/v1/')
  end
end
