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
  let(:fake) { CgminerTestSupport::FakeCgminer.new(responses: fake_responses).start }

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

  def capture_admin_log_events
    events = []
    allow(CgminerManager::Logger).to receive(:info).and_wrap_original do |m, **payload|
      events << payload if payload[:event]&.start_with?('admin.')
      m.call(**payload)
    end
    allow(CgminerManager::Logger).to receive(:warn).and_wrap_original do |m, **payload|
      events << payload if payload[:event]&.start_with?('admin.')
      m.call(**payload)
    end
    yield
    events
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

    it 'emits admin.result with failed_codes count map when miners refuse the command' do
      # Re-stub the backing fake to surface "45: Access denied" on restart so
      # FleetWriteResult sees a real ApiError → :access_denied at code_for.
      denied_fake = restub_fake_with(restart: CgminerTestSupport::Fixtures::PRIVILEGED_DENIED)

      events = capture_admin_log_events { post_admin_command(:restart) }

      result_event = events.find { |e| e[:event] == 'admin.result' }
      expect(result_event).not_to be_nil
      expect(result_event[:failed_count]).to be >= 1
      expect(result_event[:failed_codes]).to eq(access_denied: result_event[:failed_count])
    ensure
      denied_fake&.stop
    end

    def restub_fake_with(**overrides)
      fake.stop
      replacement = CgminerTestSupport::FakeCgminer.new(
        responses: fake_responses.merge(overrides.transform_keys(&:to_s))
      ).start
      path = File.join(Dir.mktmpdir, 'miners.yml')
      File.write(path, "- host: 127.0.0.1\n  port: #{replacement.port}\n")
      CgminerManager::HttpApp.configure_for_test!(
        monitor_url: 'http://localhost:9292', miners_file: path
      )
      replacement
    end

    def post_admin_command(command)
      token = fetch_csrf_token
      post "/manager/admin/#{command}",
           { authenticity_token: token },
           'HTTP_X_CSRF_TOKEN' => token
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
  end

  describe 'two-step confirmation flow (REQUIRE_CONFIRM=on)' do
    let(:basic_auth) { "Basic #{Base64.strict_encode64('operator:s3cret-value')}" }

    before do
      # AUTH=off + REQUIRE_CONFIRM=on is fail-closed (decision #16).
      # The flow tests opt INTO real Basic Auth so the destructive POSTs
      # actually exercise the gate path. One dedicated test below
      # asserts the fail-closed 503 still fires under the misalignment.
      ENV['CGMINER_MANAGER_ADMIN_USER']     = 'operator'
      ENV['CGMINER_MANAGER_ADMIN_PASSWORD'] = 's3cret-value'
      ENV['CGMINER_MANAGER_ADMIN_AUTH']     = 'on'
      CgminerManager::HttpApp.configure_confirmation_for_test!(required: true)
    end

    after { CgminerManager::HttpApp.configure_confirmation_for_test!(required: false) }

    def post_destructive(path, body = {}, headers = {})
      # Basic Auth bypasses CSRF (ConditionalAuthenticityToken), so no
      # token roundtrip needed. Hit the monitor stubs once to populate
      # configured_miners then send the POST with the auth header.
      stub_monitor_miners
      %w[summary devices pools stats].each do |endpoint|
        public_send("stub_monitor_#{endpoint}", miner_id: '127.0.0.1:4028')
        public_send("stub_monitor_#{endpoint}", miner_id: "127.0.0.1:#{fake.port}")
      end
      post path, body,
           { 'HTTP_AUTHORIZATION' => basic_auth, 'HTTP_ACCEPT' => 'application/json' }.merge(headers)
    end

    def post_confirm(token)
      post "/manager/admin/confirm/#{token}", {},
           'HTTP_AUTHORIZATION' => basic_auth, 'HTTP_ACCEPT' => 'application/json'
    end

    it 'returns 503 under AUTH=off + REQUIRE_CONFIRM=on (fail-closed misalignment)' do
      ENV.delete('CGMINER_MANAGER_ADMIN_USER')
      ENV.delete('CGMINER_MANAGER_ADMIN_PASSWORD')
      ENV['CGMINER_MANAGER_ADMIN_AUTH'] = 'off'

      stub_monitor_miners
      %w[summary devices pools stats].each do |endpoint|
        public_send("stub_monitor_#{endpoint}", miner_id: '127.0.0.1:4028')
        public_send("stub_monitor_#{endpoint}", miner_id: "127.0.0.1:#{fake.port}")
      end
      get '/'
      csrf = Rack::Protection::AuthenticityToken.token(last_request.env['rack.session'])
      post '/manager/admin/restart',
           { authenticity_token: csrf },
           'HTTP_X_CSRF_TOKEN' => csrf
      expect(last_response.status).to eq(503)
      expect(last_response.body).to include('admin confirmation requires admin auth')
    end

    it 'returns 202 + JSON pending body on a fleet-wide destructive POST without auto_confirm' do # rubocop:disable RSpec/MultipleExpectations
      events = capture_admin_log_events { post_destructive('/manager/admin/restart') }
      expect(last_response.status).to eq(202)

      body = JSON.parse(last_response.body)
      expect(body).to include(
        'status' => 'pending_confirmation',
        'command' => 'restart', 'scope' => 'all'
      )
      expect(body['confirmation_token']).to match(/\A[0-9a-f-]{36}\z/)
      expect(body['confirm_url']).to eq("/manager/admin/confirm/#{body['confirmation_token']}")

      started = events.find { |e| e[:event] == 'admin.action_started' }
      expect(started).not_to be_nil
      expect(started[:command]).to eq('restart')
      expect(started[:confirmation_token]).to eq(body['confirmation_token'])
    end

    it 'auto_confirm=1 skips the dance and dispatches in one step (admin.action_auto_confirmed emitted)' do
      events = capture_admin_log_events do
        post_destructive('/manager/admin/restart?auto_confirm=1')
      end
      expect(last_response.status).to eq(200)
      expect(events.map { |e| e[:event] }).to include('admin.action_auto_confirmed', 'admin.command')
    end

    it 'never gates read-only typed verbs even with REQUIRE_CONFIRM=on' do
      post_destructive('/manager/admin/version')
      expect(last_response.status).to eq(200)
    end

    it 'never gates per-miner destructive routes (single-rig blast radius carve-out)' do
      port = fake.port
      post_destructive("/miner/127.0.0.1%3A#{port}/admin/restart")
      expect(last_response.status).to eq(200)
    end

    it 'consume confirmation: same session dispatches the originally-pinned command' do
      events = capture_admin_log_events do
        post_destructive('/manager/admin/restart')
        token = JSON.parse(last_response.body)['confirmation_token']
        post_confirm(token)
      end
      expect(last_response.status).to eq(200)
      ev_names = events.map { |e| e[:event] }
      expect(ev_names).to include('admin.action_started', 'admin.action_confirmed', 'admin.command', 'admin.result')
    end

    it 'rejects already-consumed token with 410 + admin.action_rejected reason: :not_found' do
      events = capture_admin_log_events do
        post_destructive('/manager/admin/restart')
        token = JSON.parse(last_response.body)['confirmation_token']
        post_confirm(token)
        post_confirm(token) # second consume
      end
      expect(last_response.status).to eq(410)
      rejected = events.select { |e| e[:event] == 'admin.action_rejected' }
      expect(rejected).not_to be_empty
      expect(rejected.last[:reason]).to eq(:not_found)
    end

    it 'cancel via DELETE returns 204 + admin.action_cancelled' do
      events = capture_admin_log_events do
        post_destructive('/manager/admin/restart')
        token = JSON.parse(last_response.body)['confirmation_token']
        delete "/manager/admin/confirm/#{token}", {}, 'HTTP_AUTHORIZATION' => basic_auth
      end
      expect(last_response.status).to eq(204)
      expect(events.map { |e| e[:event] }).to include('admin.action_cancelled')
    end

    # Pool-management redaction at the helper level is covered by
    # admin_logging_spec's redact_args examples and action_started_log_entry's
    # manage_pools/add case. The route-level integration is omitted from this
    # block because /manager/manage_pools doesn't fall under AdminAuth's
    # ADMIN_PATH regex (admin_auth.rb:27), so Basic Auth doesn't bypass CSRF
    # on that path; pinning the integration would require a session-cookie +
    # CSRF roundtrip that the unit-level redaction spec already covers.
  end
end
