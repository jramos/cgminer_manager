# frozen_string_literal: true

require 'rack/test'

RSpec.describe 'GET /miner/:miner_id when monitor fails per-tile', type: :integration do
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
    stub_request(:get, %r{/v2/miners/127\.0\.0\.1.*/summary})
      .to_return(status: 503, body: '')
    stub_request(:get, %r{/v2/miners/127\.0\.0\.1.*/devices})
      .to_return(status: 503, body: '')
    stub_request(:get, %r{/v2/miners/127\.0\.0\.1.*/pools})
      .to_return(status: 503, body: '')
    stub_request(:get, %r{/v2/miners/127\.0\.0\.1.*/stats})
      .to_return(status: 503, body: '')
  end

  it 'renders the page without 500 when all tiles error' do
    get "/miner/#{CGI.escape(miner_id)}"
    expect(last_response.status).to eq(200)
    # Miner is marked unavailable → "Miner unavailable" branch of show.haml should render.
    expect(last_response.body).to match(/unavailable/i)
  end
end
