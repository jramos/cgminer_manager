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

  it 'projects {fields, data} to [[ts, ghs_5s, ghs_av], ...] for legacy Chart.js' do
    get "/miner/#{CGI.escape(miner_id)}/graph_data/hashrate"
    expect(last_response.status).to eq(200)

    body = JSON.parse(last_response.body)
    # legacy graph.js expects [ts, ghs_5s, ghs_av]
    expect(body).to eq([[1_713_262_140, 5.12, 5.10], [1_713_262_200, 5.14, 5.11]])
  end
end
