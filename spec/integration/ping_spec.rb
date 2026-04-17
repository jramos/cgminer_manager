# frozen_string_literal: true

require 'rack/test'

RSpec.describe 'GET /api/v1/ping.json', type: :integration do
  include Rack::Test::Methods

  def app = CgminerManager::HttpApp.new

  before do
    path = File.join(Dir.mktmpdir, 'miners.yml')
    File.write(path, "- host: 127.0.0.1\n  port: 4028\n")
    CgminerManager::HttpApp.configure_for_test!(
      monitor_url: 'http://localhost:9292', miners_file: path
    )
  end

  it 'returns the legacy shape {timestamp, available_miners, unavailable_miners}' do
    fake = instance_double(CgminerApiClient::Miner, available?: true)
    allow(CgminerApiClient::Miner).to receive(:new).and_return(fake)

    get '/api/v1/ping.json'
    body = JSON.parse(last_response.body, symbolize_names: true)

    expect(last_response.status).to eq(200)
    expect(body.keys).to contain_exactly(:timestamp, :available_miners, :unavailable_miners)
    expect(body[:available_miners]).to eq(1)
    expect(body[:unavailable_miners]).to eq(0)
    expect(body[:timestamp]).to be_a(Integer)
  end

  it 'counts unavailable miners when Miner#available? returns false' do
    fake = instance_double(CgminerApiClient::Miner, available?: false)
    allow(CgminerApiClient::Miner).to receive(:new).and_return(fake)

    get '/api/v1/ping.json'
    body = JSON.parse(last_response.body, symbolize_names: true)
    expect(body[:available_miners]).to eq(0)
    expect(body[:unavailable_miners]).to eq(1)
  end

  it 'does not depend on monitor being up' do
    stub_request(:get, /localhost:9292/).to_raise(Errno::ECONNREFUSED)
    fake = instance_double(CgminerApiClient::Miner, available?: true)
    allow(CgminerApiClient::Miner).to receive(:new).and_return(fake)

    get '/api/v1/ping.json'
    expect(last_response.status).to eq(200)
  end
end
