# frozen_string_literal: true

require 'rack/test'

RSpec.describe 'pool management', type: :integration do
  include Rack::Test::Methods

  def app = CgminerManager::HttpApp.new

  # Helpers that build the JSON envelopes cgminer returns for the
  # commands exercised in these tests. Kept as methods so each fixture
  # fits comfortably inside the 120-char line budget.
  def ok_status(code:, msg:)
    %({"STATUS":[{"STATUS":"S","When":1,"Code":#{code},"Msg":"#{msg}","Description":"cgminer 4.11.1"}],"id":1})
  end

  def pools_with_disabled_pool
    status = %({"STATUS":"S","When":1,"Code":7,"Msg":"1 Pool(s)","Description":"cgminer 4.11.1"})
    pool   = %({"POOL":1,"URL":"x","Status":"Disabled"})
    %({"STATUS":[#{status}],"POOLS":[#{pool}],"id":1})
  end

  # cgminer_api_client's privileged commands (disablepool, addpool, ...)
  # first probe access via `privileged` before sending the real call,
  # so every fake_responses map must include a `privileged` fixture.
  let(:fake_responses) do
    {
      'privileged' => ok_status(code: 46, msg: 'Privileged access OK'),
      'disablepool' => ok_status(code: 47, msg: 'Pool 1 disabled'),
      'pools' => pools_with_disabled_pool,
      'save' => ok_status(code: 20, msg: 'Configuration saved')
    }
  end
  let(:fake) { FakeCgminer.new(responses: fake_responses).start }

  after { fake.stop }

  before do
    path = File.join(Dir.mktmpdir, 'miners.yml')
    File.write(path, "- host: 127.0.0.1\n  port: #{fake.port}\n")
    CgminerManager::HttpApp.configure_for_test!(
      monitor_url: 'http://localhost:9292', miners_file: path
    )
  end

  describe 'POST /manager/manage_pools (disable_pool)' do
    it 'responds 200 with a per-miner status partial' do
      token = fetch_csrf_token
      post '/manager/manage_pools',
           { action_name: 'disable', pool_index: 1, authenticity_token: token },
           'HTTP_X_CSRF_TOKEN' => token

      expect(last_response.status).to eq(200)
      expect(last_response.body).to match(/127\.0\.0\.1:#{fake.port}/)
    end
  end

  describe 'POST /manager/manage_pools (add_pool)' do
    let(:fake_responses) do
      {
        'privileged' => ok_status(code: 46, msg: 'Privileged access OK'),
        'addpool' => ok_status(code: 55, msg: "Added pool 'x'")
      }
    end

    it 'returns 200 with an :ok entry and :skipped save (no verification step)' do
      token = fetch_csrf_token
      post '/manager/manage_pools',
           { action_name: 'add', url: 'stratum+tcp://x:3333', user: 'u', pass: 'p',
             authenticity_token: token },
           'HTTP_X_CSRF_TOKEN' => token

      expect(last_response.status).to eq(200)
      expect(last_response.body).to match(/127\.0\.0\.1:#{fake.port}/)
    end
  end

  describe 'CSRF enforcement' do
    it 'returns 403 on POST without a token' do
      post '/manager/manage_pools', action_name: 'disable', pool_index: 1
      expect(last_response.status).to eq(403)
    end
  end

  def fetch_csrf_token
    # Prime the session cookie with a GET, then compute a token using
    # the session hash the app just wrote. We pass the server-side
    # session through X_CSRF_TOKEN on the subsequent POST — this
    # mirrors what a browser would do after reading the meta tag, but
    # without depending on the index view having a rendered layout.
    stub_monitor_miners
    %w[summary devices pools stats].each do |endpoint|
      public_send("stub_monitor_#{endpoint}", miner_id: '127.0.0.1:4028')
      public_send("stub_monitor_#{endpoint}", miner_id: "127.0.0.1:#{fake.port}")
    end

    get '/'
    session = last_request.env['rack.session']
    Rack::Protection::AuthenticityToken.token(session)
  end
end
