# frozen_string_literal: true

require 'rack/test'

# End-to-end coverage for trace-id propagation: an admin POST goes
# through the full Rack middleware stack (RequestId → RateLimiter →
# Session → AdminAuth → CSRF → Sinatra), dispatches a cgminer command
# via FleetBuilders → CgminerCommander → ThreadedFanOut → Miner, and
# the on_wire closure threaded into each Miner emits cgminer.wire log
# events tagged with the same request_id as admin.command.
#
# Catches refactors that drop on_wire: anywhere in the
# FleetBuilders → Miner chain. Without this, a unit-level test that
# stubs Miner.new can pass green while the real fan-out path silently
# loses request_id.
RSpec.describe 'wire-logger integration', type: :integration do
  include Rack::Test::Methods

  def app = CgminerManager::HttpApp.new

  def ok_status(code:, msg:)
    %({"STATUS":[{"STATUS":"S","When":1,"Code":#{code},"Msg":"#{msg}","Description":"cgminer 4.11.1"}],"id":1})
  end

  def version_status_body
    status_json = %({"STATUS":"S","When":1,"Code":22,"Msg":"CGMiner versions","Description":"cgminer 4.11.1"})
    %({"STATUS":[#{status_json}],"VERSION":[{"CGMiner":"4.11.1"}],"id":1})
  end

  let(:fake_responses) do
    {
      'version' => version_status_body,
      'privileged' => ok_status(code: 46, msg: 'Privileged access OK')
    }
  end
  let(:fake) { CgminerTestSupport::FakeCgminer.new(responses: fake_responses).start }

  after { fake.stop }

  before do
    path = File.join(Dir.mktmpdir, 'miners.yml')
    File.write(path, "- host: 127.0.0.1\n  port: #{fake.port}\n")
    CgminerManager::HttpApp.configure_for_test!(
      monitor_url: 'http://localhost:9292', miners_file: path
    )
  end

  def fetch_csrf_token
    stub_monitor_miners
    %w[summary devices pools stats].each do |endpoint|
      public_send("stub_monitor_#{endpoint}", miner_id: '127.0.0.1:4028')
      public_send("stub_monitor_#{endpoint}", miner_id: "127.0.0.1:#{fake.port}")
    end
    get '/'
    session = last_request.env['rack.session']
    Rack::Protection::AuthenticityToken.token(session)
  end

  it 'tags cgminer.wire events with the same request_id as admin.command' do # rubocop:disable RSpec/MultipleExpectations
    captured = []
    allow(CgminerManager::Logger).to receive(:info)  { |entry| captured << entry }
    allow(CgminerManager::Logger).to receive(:debug) { |entry| captured << entry }

    token = fetch_csrf_token
    header 'X-Cgminer-Request-Id', 'integration-trace-XYZ'
    post '/manager/admin/version',
         { authenticity_token: token },
         'HTTP_X_CSRF_TOKEN' => token

    expect(last_response.status).to eq(200)

    admin_command = captured.find { |e| e[:event] == 'admin.command' }
    cgminer_wires = captured.select { |e| e[:event] == 'cgminer.wire' }

    expect(admin_command).not_to be_nil
    expect(admin_command[:request_id]).to eq('integration-trace-XYZ')
    expect(cgminer_wires).not_to be_empty
    cgminer_wires.each do |wire_event|
      expect(wire_event[:request_id]).to eq('integration-trace-XYZ')
      expect(wire_event[:miner]).to eq("127.0.0.1:#{fake.port}")
    end
  end

  it 'echoes X-Cgminer-Request-Id in the response header' do
    token = fetch_csrf_token
    header 'X-Cgminer-Request-Id', 'echo-trace-001'
    post '/manager/admin/version',
         { authenticity_token: token },
         'HTTP_X_CSRF_TOKEN' => token

    expect(last_response.headers['X-Cgminer-Request-Id']).to eq('echo-trace-001')
  end
end
