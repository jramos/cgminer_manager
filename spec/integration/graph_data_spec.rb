# frozen_string_literal: true

require 'rack/test'

RSpec.describe 'GET /miner/:miner_id/graph_data/:metric', type: :integration do
  include Rack::Test::Methods

  def app = CgminerManager::HttpApp.new
  let(:miner_id) { '127.0.0.1:4028' }

  before do
    path = File.join(Dir.mktmpdir, 'miners.yml')
    File.write(path, "- host: 127.0.0.1\n  port: 4028\n")
    CgminerManager::HttpApp.configure_for_test!(
      monitor_url: 'http://localhost:9292', miners_file: path
    )
    stub_monitor_graph(metric: 'hashrate', miner_id: miner_id,
                       fixture: 'graph_data_hashrate.json')
  end

  it 'projects {fields, data} to 7 hashrate columns for legacy Chart.js' do
    get "/miner/#{CGI.escape(miner_id)}/graph_data/hashrate"
    expect(last_response.status).to eq(200)

    body = JSON.parse(last_response.body)
    # legacy graph.js reads error metrics from hashrate columns [3]-[6]
    expect(body.first.size).to eq(7)
    expect(body).to eq([
                         [1_713_262_140, 5.12, 5.10, 0.0, 0.0, 0.99, 0.0],
                         [1_713_262_200, 5.14, 5.11, 0.0, 0.0, 0.99, 0.0]
                       ])
  end

  describe 'GET /graph_data/:metric (aggregate)' do
    it 'returns aggregate rows when no miner_id in path' do
      # No miner in path, no miner query param to monitor. Use the hashrate fixture
      # (the aggregate and per-miner shapes are equivalent for our projection
      # since we ask for column names monitor provides in both modes).
      stub_request(:get, 'http://localhost:9292/v2/graph_data/hashrate')
        .to_return(status: 200, body: File.read('spec/fixtures/monitor/graph_data_hashrate.json'),
                   headers: { 'Content-Type' => 'application/json' })

      get '/graph_data/hashrate'
      expect(last_response.status).to eq(200)

      body = JSON.parse(last_response.body)
      expect(body.first.size).to eq(7)
    end

    it 'returns 404 on unknown metric' do
      get '/graph_data/nope'
      expect(last_response.status).to eq(404)
    end
  end
end
