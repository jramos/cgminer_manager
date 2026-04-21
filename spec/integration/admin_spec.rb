# frozen_string_literal: true

require 'rack/test'
require 'base64'

RSpec.describe 'admin surface', type: :integration do
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
      'stats' => ok_status(code: 70, msg: 'CGMiner stats'),
      'devs' => ok_status(code: 9,  msg: 'Devs'),
      'zero' => ok_status(code: 72, msg: 'Zero'),
      'save' => ok_status(code: 20, msg: 'Configuration saved'),
      'restart' => ok_status(code: 42, msg: 'Restart'),
      'quit' => ok_status(code: 42, msg: 'Quit'),
      'privileged' => ok_status(code: 46, msg: 'Privileged access OK'),
      'pgaset' => ok_status(code: 72, msg: 'PGA set')
    }
  end
  let(:fake) { FakeCgminer.new(responses: fake_responses).start }

  after do
    fake.stop
    ENV.delete('CGMINER_MANAGER_ADMIN_USER')
    ENV.delete('CGMINER_MANAGER_ADMIN_PASSWORD')
    ENV['CGMINER_MANAGER_ADMIN_AUTH'] = 'off' # restore suite-level default
  end

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

  describe 'typed allowlist — POST /manager/admin/:command' do
    it 'dispatches :version with a CSRF token and returns a 200 with the response rendered' do
      token = fetch_csrf_token
      post '/manager/admin/version',
           { authenticity_token: token },
           'HTTP_X_CSRF_TOKEN' => token

      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("127.0.0.1:#{fake.port}")
      expect(last_response.body.downcase).to include('cgminer')
    end

    it 'dispatches :restart (write) and renders the fleet_write partial' do
      token = fetch_csrf_token
      post '/manager/admin/restart',
           { authenticity_token: token },
           'HTTP_X_CSRF_TOKEN' => token

      expect(last_response.status).to eq(200)
      expect(last_response.body).to include('fleet-write-result')
    end

    it 'returns 404 for a command not in the typed allowlist' do
      token = fetch_csrf_token
      post '/manager/admin/pgaset',
           { authenticity_token: token },
           'HTTP_X_CSRF_TOKEN' => token

      expect(last_response.status).to eq(404)
    end

    it 'returns 403 (CSRF required) when no token is provided' do
      post '/manager/admin/version'
      expect(last_response.status).to eq(403)
    end
  end

  describe 'raw RPC — POST /manager/admin/run' do
    it 'accepts an allowlisted scope-unrestricted verb with comma-split args' do
      token = fetch_csrf_token
      post '/manager/admin/run',
           { command: 'version', args: '', scope: 'all', authenticity_token: token },
           'HTTP_X_CSRF_TOKEN' => token

      expect(last_response.status).to eq(200)
    end

    it 'rejects whitespace in the command param with 422' do
      token = fetch_csrf_token
      post '/manager/admin/run',
           { command: 'hello world', args: '', scope: 'all', authenticity_token: token },
           'HTTP_X_CSRF_TOKEN' => token

      expect(last_response.status).to eq(422)
      expect(last_response.body).to include('invalid command')
    end

    it 'rejects scope=all for hardware-tuning verbs with 422' do
      token = fetch_csrf_token
      post '/manager/admin/run',
           { command: 'pgaset', args: '0,clock,690', scope: 'all',
             authenticity_token: token },
           'HTTP_X_CSRF_TOKEN' => token

      expect(last_response.status).to eq(422)
      expect(last_response.body).to include('scope=all')
    end

    it 'rejects unknown scope (neither "all" nor a configured miner_id)' do
      token = fetch_csrf_token
      post '/manager/admin/run',
           { command: 'version', args: '', scope: 'not-a-miner:4028',
             authenticity_token: token },
           'HTTP_X_CSRF_TOKEN' => token

      expect(last_response.status).to eq(422)
    end

    it 'accepts hardware-tuning verb when scope is a specific miner' do
      token = fetch_csrf_token
      post '/manager/admin/run',
           { command: 'pgaset', args: '0,clock,690', scope: "127.0.0.1:#{fake.port}",
             authenticity_token: token },
           'HTTP_X_CSRF_TOKEN' => token

      expect(last_response.status).to eq(200)
    end
  end

  describe 'per-miner admin — POST /miner/:id/admin/*' do
    it 'accepts a typed verb against a configured miner' do
      token = fetch_csrf_token
      post "/miner/127.0.0.1%3A#{fake.port}/admin/version",
           { authenticity_token: token },
           'HTTP_X_CSRF_TOKEN' => token

      expect(last_response.status).to eq(200)
    end

    it 'returns 404 for an unconfigured miner id' do
      token = fetch_csrf_token
      post '/miner/9.9.9.9%3A4028/admin/version',
           { authenticity_token: token },
           'HTTP_X_CSRF_TOKEN' => token

      expect(last_response.status).to eq(404)
    end
  end

  describe 'Basic Auth gate' do
    it 'requires credentials when both env vars are set' do
      ENV['CGMINER_MANAGER_ADMIN_USER']     = 'operator'
      ENV['CGMINER_MANAGER_ADMIN_PASSWORD'] = 's3cret-value'

      post '/manager/admin/version'
      expect(last_response.status).to eq(401)
      expect(last_response.headers['WWW-Authenticate']).to include('Basic')
    end

    it 'accepts correct Basic Auth credentials and bypasses CSRF' do
      ENV['CGMINER_MANAGER_ADMIN_USER']     = 'operator'
      ENV['CGMINER_MANAGER_ADMIN_PASSWORD'] = 's3cret-value'

      header 'Authorization', "Basic #{Base64.strict_encode64('operator:s3cret-value')}"
      post '/manager/admin/version'

      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("127.0.0.1:#{fake.port}")
    end

    it 'treats empty-string creds + CGMINER_MANAGER_ADMIN_AUTH=off as an open gate' do
      ENV['CGMINER_MANAGER_ADMIN_USER']     = ''
      ENV['CGMINER_MANAGER_ADMIN_PASSWORD'] = ''
      ENV['CGMINER_MANAGER_ADMIN_AUTH']     = 'off'

      # CSRF still enforced, so this returns 403 — proves the Basic Auth
      # middleware is not asking for credentials (would otherwise 401).
      post '/manager/admin/version'
      expect(last_response.status).to eq(403)
    end

    # Only reachable in tests because HttpApp.configure_for_test! mounts
    # middleware without going through Config.from_env — in production,
    # boot-time validation fails before the process accepts a request.
    # The 503 branch covers post-boot ENV tampering (and this regression).
    it 'returns 503 when auth is required (no escape hatch) and creds are missing' do
      ENV.delete('CGMINER_MANAGER_ADMIN_AUTH')
      ENV.delete('CGMINER_MANAGER_ADMIN_USER')
      ENV.delete('CGMINER_MANAGER_ADMIN_PASSWORD')

      post '/manager/admin/version'
      expect(last_response.status).to eq(503)
      expect(last_response.body).to include('admin authentication is misconfigured')
    end
  end

  describe 'audit logging' do
    it 'emits admin.command + admin.result with a shared request_id' do
      events = capture_admin_log_events do
        token = fetch_csrf_token
        post '/manager/admin/version',
             { authenticity_token: token },
             'HTTP_X_CSRF_TOKEN' => token
      end

      command_event = events.find { |e| e[:event] == 'admin.command' }
      result_event  = events.find { |e| e[:event] == 'admin.result' }

      expect(command_event).not_to be_nil
      expect(result_event).not_to be_nil
      expect(command_event[:request_id]).to eq(result_event[:request_id])
      expect(command_event[:command]).to eq('version')
      expect(result_event[:scope]).to eq('all')
    end

    it 'emits admin.raw_command with command + args + scope captured verbatim' do
      events = capture_admin_log_events do
        token = fetch_csrf_token
        post '/manager/admin/run',
             { command: 'version', args: 'foo,bar', scope: 'all', authenticity_token: token },
             'HTTP_X_CSRF_TOKEN' => token
      end

      raw_event = events.find { |e| e[:event] == 'admin.raw_command' }
      expect(raw_event).not_to be_nil
      expect(raw_event[:command]).to eq('version')
      expect(raw_event[:args]).to eq('foo,bar')
      expect(raw_event[:scope]).to eq('all')
    end

    def capture_admin_log_events
      events = []
      allow(CgminerManager::Logger).to receive(:info).and_wrap_original do |m, **payload|
        events << payload if payload[:event]&.start_with?('admin.')
        m.call(**payload)
      end
      yield
      events
    end
  end
end
