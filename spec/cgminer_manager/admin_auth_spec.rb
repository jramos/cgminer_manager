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
    original_user = ENV.fetch('CGMINER_MANAGER_ADMIN_USER', nil)
    original_pass = ENV.fetch('CGMINER_MANAGER_ADMIN_PASSWORD', nil)
    example.run
  ensure
    ENV['CGMINER_MANAGER_ADMIN_USER']     = original_user
    ENV['CGMINER_MANAGER_ADMIN_PASSWORD'] = original_pass
  end

  context 'when admin creds are unset' do
    before do
      ENV.delete('CGMINER_MANAGER_ADMIN_USER')
      ENV.delete('CGMINER_MANAGER_ADMIN_PASSWORD')
    end

    it 'passes admin requests through without setting the authed flag' do
      status, _h, body = middleware.call(request_env(path: '/manager/admin/version'))
      expect(status).to eq(200)
      expect(body.first).to eq('') # flag unset, to_s is ''
    end

    it 'passes non-admin requests through' do
      status, = middleware.call(request_env(path: '/manager/manage_pools'))
      expect(status).to eq(200)
    end
  end

  context 'when admin creds are set to empty strings (treated as unset)' do
    before do
      ENV['CGMINER_MANAGER_ADMIN_USER']     = ''
      ENV['CGMINER_MANAGER_ADMIN_PASSWORD'] = ''
    end

    it 'does not require auth' do
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
