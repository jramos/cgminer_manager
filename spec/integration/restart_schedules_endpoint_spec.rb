# frozen_string_literal: true

require 'rack/test'
require 'tmpdir'
require 'json'

RSpec.describe 'GET /api/v1/restart_schedules.json', type: :integration do
  include Rack::Test::Methods

  def app = CgminerManager::HttpApp.new

  let(:tmpdir) { Dir.mktmpdir('schedules_endpoint') }
  let(:miners_file) do
    path = File.join(tmpdir, 'miners.yml')
    File.write(path, "- host: 127.0.0.1\n  port: 4028\n")
    path
  end
  let(:store_path) { File.join(tmpdir, 'restart_schedules.json') }
  let(:store) { CgminerManager::RestartStore.new(store_path) }

  after { FileUtils.remove_entry(tmpdir) }

  context 'when no store is configured' do
    before do
      CgminerManager::HttpApp.configure_for_test!(
        monitor_url: 'http://localhost:9292',
        miners_file: miners_file,
        restart_store: nil
      )
    end

    it 'returns an empty schedules list with a generated_at timestamp' do
      get '/api/v1/restart_schedules.json'
      expect(last_response.status).to eq(200)
      expect(last_response.headers['Content-Type']).to include('application/json')

      payload = JSON.parse(last_response.body)
      expect(payload['schedules']).to eq([])
      expect(payload['generated_at']).to match(/\A\d{4}-\d{2}-\d{2}T/)
    end
  end

  context 'with one schedule' do
    before do
      store.replace('127.0.0.1:4028' => CgminerManager::RestartSchedule.build(
        miner_id: '127.0.0.1:4028', enabled: true, time_utc: '04:00',
        last_restart_at: '2026-04-23T04:00:14Z', last_scheduled_date_utc: '2026-04-23'
      ))
      CgminerManager::HttpApp.configure_for_test!(
        monitor_url: 'http://localhost:9292',
        miners_file: miners_file,
        restart_store: store
      )
    end

    it 'returns the schedule with all fields' do
      get '/api/v1/restart_schedules.json'
      expect(last_response.status).to eq(200)

      payload = JSON.parse(last_response.body)
      expect(payload['schedules'].size).to eq(1)
      expect(payload['schedules'].first).to include(
        'miner_id' => '127.0.0.1:4028',
        'enabled' => true,
        'time_utc' => '04:00',
        'last_restart_at' => '2026-04-23T04:00:14Z',
        'last_scheduled_date_utc' => '2026-04-23'
      )
    end

    it 'is unauthenticated even when admin auth is required' do
      ENV.delete('CGMINER_MANAGER_ADMIN_AUTH')
      ENV['CGMINER_MANAGER_ADMIN_USER']     = 'operator'
      ENV['CGMINER_MANAGER_ADMIN_PASSWORD'] = 's3cret'

      get '/api/v1/restart_schedules.json'
      expect(last_response.status).to eq(200)
    ensure
      ENV.delete('CGMINER_MANAGER_ADMIN_USER')
      ENV.delete('CGMINER_MANAGER_ADMIN_PASSWORD')
      ENV['CGMINER_MANAGER_ADMIN_AUTH'] = 'off'
    end
  end
end
