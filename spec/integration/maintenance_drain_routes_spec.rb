# frozen_string_literal: true

require 'rack/test'
require 'tmpdir'
require 'base64'
require 'json'

RSpec.describe 'maintenance drain routes', type: :integration do # rubocop:disable RSpec/MultipleMemoizedHelpers
  include Rack::Test::Methods

  def app = CgminerManager::HttpApp.new

  let(:tmpdir) { Dir.mktmpdir('drain_spec') }
  let(:miners_file) do
    path = File.join(tmpdir, 'miners.yml')
    File.write(path, "- host: 127.0.0.1\n  port: 4028\n")
    path
  end
  let(:store_path) { File.join(tmpdir, 'restart_schedules.json') }
  let(:store) { CgminerManager::RestartStore.new(store_path) }
  let(:miner_id) { '127.0.0.1:4028' }
  let(:fake_pool_manager) { instance_double(CgminerManager::PoolManager) }

  def ok_pool_result
    entry = CgminerManager::PoolManager::MinerEntry.new(
      miner: nil, command_status: :ok, command_reason: nil,
      save_status: :ok, save_reason: nil
    )
    CgminerManager::PoolManager::PoolActionResult.new(entries: [entry])
  end

  def failed_pool_result(reason = 'connect timeout')
    entry = CgminerManager::PoolManager::MinerEntry.new(
      miner: nil, command_status: :failed, command_reason: reason,
      save_status: :failed, save_reason: reason
    )
    CgminerManager::PoolManager::PoolActionResult.new(entries: [entry])
  end

  def indeterminate_pool_result
    entry = CgminerManager::PoolManager::MinerEntry.new(
      miner: nil, command_status: :indeterminate, command_reason: 'DidNotConverge',
      save_status: :ok, save_reason: nil
    )
    CgminerManager::PoolManager::PoolActionResult.new(entries: [entry])
  end

  before do
    CgminerManager::HttpApp.configure_for_test!(
      monitor_url: 'http://localhost:9292',
      miners_file: miners_file,
      restart_store: store
    )
    allow(CgminerManager::PoolManager).to receive(:new).and_return(fake_pool_manager)
  end

  after do
    ENV['CGMINER_MANAGER_ADMIN_AUTH'] = 'off'
    FileUtils.remove_entry(tmpdir)
  end

  def fetch_csrf_token
    get "/miner/#{miner_id}/maintenance"
    Rack::Protection::AuthenticityToken.token(last_request.env['rack.session'] || {})
  end

  def post_drain
    csrf = fetch_csrf_token
    post "/miner/#{miner_id}/maintenance/drain",
         { authenticity_token: csrf },
         'HTTP_X_CSRF_TOKEN' => csrf
  end

  def post_resume
    csrf = fetch_csrf_token
    post "/miner/#{miner_id}/maintenance/resume",
         { authenticity_token: csrf },
         'HTTP_X_CSRF_TOKEN' => csrf
  end

  def capture_drain_log_events
    events = []
    %i[info warn].each do |level|
      allow(CgminerManager::Logger).to receive(level).and_wrap_original do |m, **payload|
        events << payload if payload[:event]&.start_with?('drain.')
        m.call(**payload)
      end
    end
    yield
    events
  end

  describe 'POST /miner/:id/maintenance/drain' do # rubocop:disable RSpec/MultipleMemoizedHelpers
    it 'persists drained=true on :ok and emits drain.applied' do
      allow(fake_pool_manager).to receive(:disable_pool).with(pool_index: 0).and_return(ok_pool_result)
      events = capture_drain_log_events { post_drain }

      expect(last_response.status).to eq(200)
      persisted = store.load[miner_id]
      expect(persisted.drained).to be(true)
      expect(persisted.drained_at).not_to be_nil
      expect(events.map { |e| e[:event] }).to include('drain.applied')
      expect(events.find { |e| e[:event] == 'drain.applied' }[:auto_resume_seconds]).to eq(3600)
    end

    it 'creates a default schedule on a never-scheduled miner (review C3)' do
      expect(store.load[miner_id]).to be_nil
      allow(fake_pool_manager).to receive(:disable_pool).and_return(ok_pool_result)
      post_drain

      persisted = store.load[miner_id]
      expect(persisted).not_to be_nil
      expect(persisted.enabled).to be(false)
      expect(persisted.time_utc).to be_nil
      expect(persisted.drained).to be(true)
    end

    it 'fails-open on :failed: store unchanged, drain.failed emitted, 502' do
      allow(fake_pool_manager).to receive(:disable_pool).and_return(failed_pool_result('refused'))
      events = capture_drain_log_events { post_drain }

      expect(last_response.status).to eq(502)
      expect(store.load[miner_id]).to be_nil
      drain_failed = events.find { |e| e[:event] == 'drain.failed' }
      expect(drain_failed).to include(cause: :drain, error: 'refused')
    end

    it 'fails-closed on :indeterminate: store reflects drained=true (decision #6)' do
      allow(fake_pool_manager).to receive(:disable_pool).and_return(indeterminate_pool_result)
      events = capture_drain_log_events { post_drain }

      expect(last_response.status).to eq(200)
      expect(store.load[miner_id].drained).to be(true)
      expect(events.map { |e| e[:event] }).to include('drain.applied', 'drain.indeterminate')
    end

    it 'returns 422 when the miner is already drained' do
      store.replace(miner_id => CgminerManager::RestartSchedule.build(
        miner_id: miner_id, enabled: false, time_utc: nil,
        last_restart_at: nil, last_scheduled_date_utc: nil,
        drained: true, drained_at: '2026-04-26T12:00:00.000Z', drained_by: 'op'
      ))
      post_drain
      expect(last_response.status).to eq(422)
      expect(last_response.body).to include('already drained')
    end

    it 'returns 404 for an unconfigured miner_id' do
      csrf = fetch_csrf_token
      post '/miner/9.9.9.9%3A4028/maintenance/drain',
           { authenticity_token: csrf },
           'HTTP_X_CSRF_TOKEN' => csrf
      expect(last_response.status).to eq(404)
    end
  end

  describe 'POST /miner/:id/maintenance/resume' do # rubocop:disable RSpec/MultipleMemoizedHelpers
    before do
      store.replace(miner_id => CgminerManager::RestartSchedule.build(
        miner_id: miner_id, enabled: true, time_utc: '04:00',
        last_restart_at: nil, last_scheduled_date_utc: nil,
        drained: true, drained_at: '2026-04-26T12:00:00.000Z', drained_by: 'op'
      ))
    end

    it 'clears drain on :ok and emits drain.resumed cause: :operator' do
      allow(fake_pool_manager).to receive(:enable_pool).with(pool_index: 0).and_return(ok_pool_result)
      events = capture_drain_log_events { post_resume }

      expect(last_response.status).to eq(200)
      persisted = store.load[miner_id]
      expect(persisted.drained).to be(false)
      expect(persisted.drained_at).to be_nil
      drain_resumed = events.find { |e| e[:event] == 'drain.resumed' }
      expect(drain_resumed[:cause]).to eq(:operator)
      expect(drain_resumed[:drained_at]).to eq('2026-04-26T12:00:00.000Z')
    end

    it 'preserves enabled + time_utc on resume (drain is independent of schedule)' do
      allow(fake_pool_manager).to receive(:enable_pool).and_return(ok_pool_result)
      post_resume
      persisted = store.load[miner_id]
      expect(persisted.enabled).to be(true)
      expect(persisted.time_utc).to eq('04:00')
    end

    it 'fails-open on :failed: drain stays put, drain.failed emitted, 502' do
      allow(fake_pool_manager).to receive(:enable_pool).and_return(failed_pool_result)
      events = capture_drain_log_events { post_resume }

      expect(last_response.status).to eq(502)
      expect(store.load[miner_id].drained).to be(true)
      expect(events.find { |e| e[:event] == 'drain.failed' }[:cause]).to eq(:resume)
    end

    it 'fails-open on :indeterminate: drain CLEARS anyway (decision #6)' do
      allow(fake_pool_manager).to receive(:enable_pool).and_return(indeterminate_pool_result)
      events = capture_drain_log_events { post_resume }

      expect(last_response.status).to eq(200)
      expect(store.load[miner_id].drained).to be(false)
      expect(events.map { |e| e[:event] }).to include('drain.resumed', 'drain.indeterminate')
    end

    it 'returns 422 when the miner is not currently drained' do
      store.replace(miner_id => CgminerManager::RestartSchedule.build(
        miner_id: miner_id, enabled: false, time_utc: nil,
        last_restart_at: nil, last_scheduled_date_utc: nil
      ))
      post_resume
      expect(last_response.status).to eq(422)
      expect(last_response.body).to include('not drained')
    end
  end

  describe 'maintenance edit preserves drain state across schedule changes' do # rubocop:disable RSpec/MultipleMemoizedHelpers
    before do
      store.replace(miner_id => CgminerManager::RestartSchedule.build(
        miner_id: miner_id, enabled: false, time_utc: nil,
        last_restart_at: nil, last_scheduled_date_utc: nil,
        drained: true, drained_at: '2026-04-26T12:00:00.000Z', drained_by: 'op'
      ))
    end

    it 'editing the maintenance schedule does NOT clear an active drain' do
      csrf = fetch_csrf_token
      post "/miner/#{miner_id}/maintenance",
           { authenticity_token: csrf, enabled: '1', time_utc: '05:30' },
           'HTTP_X_CSRF_TOKEN' => csrf

      persisted = store.load[miner_id]
      expect(persisted.enabled).to be(true)
      expect(persisted.time_utc).to eq('05:30')
      expect(persisted.drained).to be(true)
      expect(persisted.drained_at).to eq('2026-04-26T12:00:00.000Z')
    end
  end
end
