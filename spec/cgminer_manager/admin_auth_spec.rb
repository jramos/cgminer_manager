# frozen_string_literal: true

require 'rack/mock'
require 'base64'

RSpec.describe CgminerManager::AdminAuth do
  let(:downstream) do
    ->(env) { [200, { 'Content-Type' => 'text/plain' }, [env['cgminer_manager.admin_authed'].to_s]] }
  end
  let(:middleware) { described_class.new(downstream) }

  def request_env(path:, auth: nil)
    env = Rack::MockRequest.env_for(path, method: 'POST')
    env['HTTP_AUTHORIZATION'] = "Basic #{Base64.strict_encode64(auth)}" if auth
    env
  end

  around do |example|
    originals = ENV.to_h.slice(
      'CGMINER_MANAGER_ADMIN_USER',
      'CGMINER_MANAGER_ADMIN_PASSWORD',
      'CGMINER_MANAGER_ADMIN_AUTH'
    )
    example.run
  ensure
    %w[CGMINER_MANAGER_ADMIN_USER CGMINER_MANAGER_ADMIN_PASSWORD CGMINER_MANAGER_ADMIN_AUTH].each do |k|
      originals.key?(k) ? ENV[k] = originals[k] : ENV.delete(k)
    end
  end

  context 'when admin auth is explicitly disabled (CGMINER_MANAGER_ADMIN_AUTH=off)' do
    before do
      ENV.delete('CGMINER_MANAGER_ADMIN_USER')
      ENV.delete('CGMINER_MANAGER_ADMIN_PASSWORD')
      ENV['CGMINER_MANAGER_ADMIN_AUTH'] = 'off'
    end

    it 'passes admin requests through without demanding credentials' do
      status, = middleware.call(request_env(path: '/manager/admin/version'))
      expect(status).to eq(200)
    end

    it 'does not set the admin_authed env flag (still anonymous)' do
      _s, _h, body = middleware.call(request_env(path: '/manager/admin/version'))
      expect(body.first).to eq('') # flag unset, to_s is ''
    end

    it 'passes non-admin requests through' do
      status, = middleware.call(request_env(path: '/manager/manage_pools'))
      expect(status).to eq(200)
    end
  end

  context 'when admin creds are missing and the escape hatch is NOT set' do
    before do
      ENV.delete('CGMINER_MANAGER_ADMIN_USER')
      ENV.delete('CGMINER_MANAGER_ADMIN_PASSWORD')
      ENV.delete('CGMINER_MANAGER_ADMIN_AUTH')
    end

    it 'returns 503 with an operator-facing misconfig body on admin paths' do
      status, headers, body = middleware.call(request_env(path: '/manager/admin/version'))
      expect(status).to eq(503)
      expect(headers['Content-Type']).to eq('text/plain')
      expect(body.first).to include('admin authentication is misconfigured')
    end

    it 'logs admin.auth_misconfigured with path + remote_ip + user_agent for forensics' do
      allow(CgminerManager::Logger).to receive(:warn)
      middleware.call(request_env(path: '/manager/admin/version'))
      expect(CgminerManager::Logger).to have_received(:warn).with(
        hash_including(
          event: 'admin.auth_misconfigured',
          path: '/manager/admin/version',
          remote_ip: anything,
          user_agent: anything
        )
      )
    end

    it 'returns 503 without a WWW-Authenticate header (config failure, not auth challenge)' do
      _status, headers, = middleware.call(request_env(path: '/manager/admin/version'))
      expect(headers).not_to have_key('WWW-Authenticate')
    end

    it 'still passes non-admin requests through' do
      status, = middleware.call(request_env(path: '/manager/manage_pools'))
      expect(status).to eq(200)
    end
  end

  context 'when creds are empty strings and auth is disabled' do
    before do
      ENV['CGMINER_MANAGER_ADMIN_USER']     = ''
      ENV['CGMINER_MANAGER_ADMIN_PASSWORD'] = ''
      ENV['CGMINER_MANAGER_ADMIN_AUTH']     = 'off'
    end

    it 'does not require auth (empty strings + explicit off)' do
      status, = middleware.call(request_env(path: '/manager/admin/version'))
      expect(status).to eq(200)
    end
  end

  context 'when admin creds are set' do
    before do
      ENV['CGMINER_MANAGER_ADMIN_USER']     = 'admin'
      ENV['CGMINER_MANAGER_ADMIN_PASSWORD'] = 's3cret'
    end

    it 'does not touch non-admin paths' do
      status, = middleware.call(request_env(path: '/manager/manage_pools'))
      expect(status).to eq(200)
    end

    it 'rejects admin paths without credentials (401 + WWW-Authenticate)' do
      status, headers, body = middleware.call(request_env(path: '/manager/admin/version'))
      expect(status).to eq(401)
      expect(headers['WWW-Authenticate']).to include('Basic')
      expect(body.first).to include('Admin authentication required')
    end

    it 'rejects admin paths with wrong password' do
      status, = middleware.call(request_env(path: '/manager/admin/version', auth: 'admin:wrong'))
      expect(status).to eq(401)
    end

    it 'rejects admin paths with wrong username' do
      status, = middleware.call(request_env(path: '/manager/admin/version', auth: 'someone:s3cret'))
      expect(status).to eq(401)
    end

    it 'accepts correct credentials and marks the env flag' do
      status, _h, body = middleware.call(request_env(path: '/manager/admin/version', auth: 'admin:s3cret'))
      expect(status).to eq(200)
      expect(body.first).to eq('true')
    end

    it 'accepts credentials on per-miner admin routes' do
      status, = middleware.call(
        request_env(path: '/miner/192.168.1.151%3A4028/admin/version', auth: 'admin:s3cret')
      )
      expect(status).to eq(200)
    end

    it 'logs admin.auth_failed with structured reason on rejection' do
      allow(CgminerManager::Logger).to receive(:warn)

      middleware.call(request_env(path: '/manager/admin/version', auth: 'admin:wrong'))

      expect(CgminerManager::Logger).to have_received(:warn).with(
        hash_including(event: 'admin.auth_failed', reason: :bad_creds)
      )
    end

    # Precedence rule: a stale =off must not bypass rotated-in creds.
    # Pins the `auth_disabled? && !configured?` guard in AdminAuth#call.
    context 'when CGMINER_MANAGER_ADMIN_AUTH=off is also set (stale hatch)' do
      before { ENV['CGMINER_MANAGER_ADMIN_AUTH'] = 'off' }

      it 'still requires credentials (creds-set wins over =off)' do
        status, headers, = middleware.call(request_env(path: '/manager/admin/version'))
        expect(status).to eq(401)
        expect(headers['WWW-Authenticate']).to include('Basic')
      end

      it 'still accepts valid credentials' do
        status, = middleware.call(request_env(path: '/manager/admin/version', auth: 'admin:s3cret'))
        expect(status).to eq(200)
      end
    end
  end
end

RSpec.describe CgminerManager::ConditionalAuthenticityToken do
  let(:downstream) { ->(_env) { [200, {}, ['ok']] } }

  it 'skips CSRF when the admin_authed flag is set' do
    middleware = described_class.new(downstream)
    env = Rack::MockRequest.env_for('/manager/admin/version', method: 'POST')
    env['cgminer_manager.admin_authed'] = true
    env['rack.session'] = {}

    status, = middleware.call(env)

    expect(status).to eq(200)
  end

  it 'falls through to CSRF enforcement when the flag is absent' do
    middleware = described_class.new(downstream)
    env = Rack::MockRequest.env_for('/manager/manage_pools', method: 'POST')
    env['rack.session'] = {}

    status, = middleware.call(env)

    expect(status).to eq(403) # rack-protection default: no token -> forbidden
  end
end
