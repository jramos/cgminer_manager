# frozen_string_literal: true

require 'rack/test'
require 'tmpdir'

RSpec.describe 'maintenance routes', type: :integration do
  include Rack::Test::Methods

  def app = CgminerManager::HttpApp.new

  let(:tmpdir) { Dir.mktmpdir('maint_spec') }
  let(:miners_file) do
    path = File.join(tmpdir, 'miners.yml')
    File.write(path, "- host: 127.0.0.1\n  port: 4028\n")
    path
  end
  let(:store_path) { File.join(tmpdir, 'restart_schedules.json') }
  let(:store) { CgminerManager::RestartStore.new(store_path) }
  let(:miner_id) { '127.0.0.1:4028' }

  before do
    CgminerManager::HttpApp.configure_for_test!(
      monitor_url: 'http://localhost:9292',
      miners_file: miners_file,
      restart_store: store
    )
  end

  after do
    ENV['CGMINER_MANAGER_ADMIN_AUTH'] = 'off' # restore suite-level default
    ENV.delete('CGMINER_MANAGER_ADMIN_USER')
    ENV.delete('CGMINER_MANAGER_ADMIN_PASSWORD')
    FileUtils.remove_entry(tmpdir)
  end

  def basic_auth_header(user, pass)
    "Basic #{Base64.strict_encode64("#{user}:#{pass}")}"
  end

  def fetch_csrf_token
    get "/miner/#{miner_id}/maintenance"
    Rack::Protection::AuthenticityToken.token(last_request.env['rack.session'] || {})
  end

  describe 'AdminAuth gate (proves the regex extension)' do
    before do
      ENV.delete('CGMINER_MANAGER_ADMIN_AUTH')
      ENV['CGMINER_MANAGER_ADMIN_USER']     = 'operator'
      ENV['CGMINER_MANAGER_ADMIN_PASSWORD'] = 's3cret'
    end

    it 'returns 401 on GET /miner/:id/maintenance without basic-auth' do
      get "/miner/#{miner_id}/maintenance"
      expect(last_response.status).to eq(401)
    end

    it 'returns 401 on POST /miner/:id/maintenance without basic-auth' do
      post "/miner/#{miner_id}/maintenance"
      expect(last_response.status).to eq(401)
    end

    it 'lets the request through with valid basic-auth' do
      header 'Authorization', basic_auth_header('operator', 's3cret')
      get "/miner/#{miner_id}/maintenance"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include('Scheduled Restart')
    end
  end

  describe 'GET /miner/:id/maintenance' do
    it 'returns the form populated from the store' do
      store.replace(miner_id => CgminerManager::RestartSchedule.build(
        miner_id: miner_id, enabled: true, time_utc: '04:00',
        last_restart_at: '2026-04-23T04:00:14Z', last_scheduled_date_utc: '2026-04-23'
      ))
      get "/miner/#{miner_id}/maintenance"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to match(/value=['"]04:00['"]/)
      expect(last_response.body).to include('checked')
      expect(last_response.body).to include('2026-04-23T04:00:14Z')
    end

    it 'returns a default-disabled form when no entry exists' do
      get "/miner/#{miner_id}/maintenance"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include('Scheduled Restart')
      expect(last_response.body).not_to match(/checked/)
    end

    it 'returns 404 for an unconfigured miner' do
      get '/miner/9.9.9.9:4028/maintenance'
      expect(last_response.status).to eq(404)
    end
  end

  describe 'POST /miner/:id/maintenance' do
    it 'persists a new schedule and re-renders the partial' do
      token = fetch_csrf_token
      post "/miner/#{miner_id}/maintenance",
           { authenticity_token: token, enabled: '1', time_utc: '05:30' },
           'HTTP_X_CSRF_TOKEN' => token

      expect(last_response.status).to eq(200)
      expect(last_response.body).to match(/value=['"]05:30['"]/)

      persisted = store.load[miner_id]
      expect(persisted.enabled).to be(true)
      expect(persisted.time_utc).to eq('05:30')
    end

    it 'preserves last_restart_at + last_scheduled_date_utc on update' do
      store.replace(miner_id => CgminerManager::RestartSchedule.build(
        miner_id: miner_id, enabled: true, time_utc: '04:00',
        last_restart_at: '2026-04-23T04:00:14Z', last_scheduled_date_utc: '2026-04-23'
      ))
      token = fetch_csrf_token
      post "/miner/#{miner_id}/maintenance",
           { authenticity_token: token, enabled: '1', time_utc: '05:30' },
           'HTTP_X_CSRF_TOKEN' => token

      persisted = store.load[miner_id]
      expect(persisted.last_restart_at).to eq('2026-04-23T04:00:14Z')
      expect(persisted.last_scheduled_date_utc).to eq('2026-04-23')
    end

    it 'returns 422 with the form re-rendered for an invalid time' do
      token = fetch_csrf_token
      post "/miner/#{miner_id}/maintenance",
           { authenticity_token: token, enabled: '1', time_utc: '25:99' },
           'HTTP_X_CSRF_TOKEN' => token

      expect(last_response.status).to eq(422)
      expect(last_response.body).to include('Scheduled Restart')
      expect(last_response.body).to match(/time_utc/)
    end

    it 'accepts disabled with no time_utc' do
      token = fetch_csrf_token
      post "/miner/#{miner_id}/maintenance",
           { authenticity_token: token, time_utc: '' },
           'HTTP_X_CSRF_TOKEN' => token

      expect(last_response.status).to eq(200)
      persisted = store.load[miner_id]
      expect(persisted.enabled).to be(false)
      expect(persisted.time_utc).to be_nil
    end
  end

  describe 'route handler and scheduler share the singleton store' do
    it 'a POST mutation is observable via settings.restart_store' do
      token = fetch_csrf_token
      post "/miner/#{miner_id}/maintenance",
           { authenticity_token: token, enabled: '1', time_utc: '03:30' },
           'HTTP_X_CSRF_TOKEN' => token

      via_settings = CgminerManager::HttpApp.settings.restart_store
      expect(via_settings).to equal(store)
      expect(via_settings.load[miner_id].time_utc).to eq('03:30')
    end
  end
end
