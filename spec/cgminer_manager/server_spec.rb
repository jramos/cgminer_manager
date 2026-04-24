# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# Focused unit coverage for Server#configure_http_app. The full Server#run
# lifecycle (Puma boot, signal handling) is integration-tested elsewhere;
# here we just pin the "all 8 settings land, miners.yml is eager-parsed"
# invariant that the PR #11 migration introduced.
RSpec.describe CgminerManager::Server do
  subject(:server) { described_class.new(config) }

  let(:tmpdir) { Dir.mktmpdir('server_spec') }
  let(:miners_file) do
    path = File.join(tmpdir, 'miners.yml')
    File.write(path, "- host: 10.0.0.1\n  port: 4028\n  label: rig-a\n")
    path
  end

  let(:schedules_file) { File.join(tmpdir, 'restart_schedules.json') }

  let(:config) do
    instance_double(
      CgminerManager::Config,
      monitor_url: 'http://monitor:9292',
      miners_file: miners_file,
      stale_threshold_seconds: 300,
      pool_thread_cap: 8,
      monitor_timeout: 2500,
      session_secret: 'a' * 64,
      production?: false,
      rate_limit_enabled: true,
      rate_limit_requests: 60,
      rate_limit_window_seconds: 60,
      trusted_proxies: [],
      restart_schedules_file: schedules_file,
      restart_scheduler_enabled: true,
      shutdown_timeout: 10
    )
  end

  before do
    # Reset HttpApp settings to known state so ordering across examples
    # doesn't muddy the assertions.
    CgminerManager::HttpApp.set :monitor_url,               nil
    CgminerManager::HttpApp.set :miners_file,               nil
    CgminerManager::HttpApp.set :configured_miners,         nil
    CgminerManager::HttpApp.set :stale_threshold_seconds,   300
    CgminerManager::HttpApp.set :pool_thread_cap,           8
    CgminerManager::HttpApp.set :monitor_timeout_ms,        2000
    CgminerManager::HttpApp.set :session_secret,            nil
    CgminerManager::HttpApp.set :production,                false
    CgminerManager::HttpApp.set :rate_limit_enabled,        false
    CgminerManager::HttpApp.set :rate_limit_requests,       60
    CgminerManager::HttpApp.set :rate_limit_window_seconds, 60
    CgminerManager::HttpApp.set :trusted_proxies,           []
    CgminerManager::HttpApp.set :restart_store,             nil
  end

  after do
    FileUtils.remove_entry(tmpdir)
  end

  describe '#configure_http_app' do
    it 'writes every Config-derived Sinatra setting on HttpApp' do
      server.send(:configure_http_app)

      app_settings = CgminerManager::HttpApp.settings
      expect(
        monitor_url: app_settings.monitor_url,
        miners_file: app_settings.miners_file,
        stale_threshold_seconds: app_settings.stale_threshold_seconds,
        pool_thread_cap: app_settings.pool_thread_cap,
        monitor_timeout_ms: app_settings.monitor_timeout_ms,
        session_secret: app_settings.session_secret,
        production: app_settings.production
      ).to eq(
        monitor_url: 'http://monitor:9292',
        miners_file: miners_file,
        stale_threshold_seconds: 300,
        pool_thread_cap: 8,
        monitor_timeout_ms: 2500,
        session_secret: 'a' * 64,
        production: false
      )
    end

    it 'eager-parses miners.yml into settings.configured_miners' do
      server.send(:configure_http_app)

      expect(CgminerManager::HttpApp.settings.configured_miners)
        .to eq([['10.0.0.1', 4028, 'rig-a'].freeze])
    end

    it 'raises ConfigError at configure time for a malformed miners.yml' do
      File.write(miners_file, '- just_a_string')
      expect { server.send(:configure_http_app) }
        .to raise_error(CgminerManager::ConfigError, /must be a YAML list/)
    end

    # Regression guard — session-cookie middleware must be installed
    # AFTER settings are populated so the operator's configured secret
    # is the one captured by `use`.
    it 'installs middleware with the operator-configured session secret' do
      server.send(:configure_http_app)

      session_middleware = CgminerManager::HttpApp.middleware.find { |m| m.first == Rack::Session::Cookie }
      expect(session_middleware[1].first[:secret]).to eq('a' * 64)
    end

    # The RestartStore singleton must be the SAME instance shared
    # between HTTP request handlers and the RestartScheduler thread —
    # otherwise route POSTs and scheduler ticks each hold their own
    # mutex and concurrent writes can tear.
    it 'builds a singleton RestartStore and stashes it on HttpApp settings' do
      server.send(:configure_http_app)
      stored = CgminerManager::HttpApp.settings.restart_store
      expect(stored).to be_a(CgminerManager::RestartStore)
      expect(stored.path).to eq(schedules_file)
      expect(server.instance_variable_get(:@restart_store)).to equal(stored)
    end
  end

  describe '#start_restart_scheduler' do
    before do
      server.send(:configure_http_app)
      allow(CgminerManager::Logger).to receive(:info)
    end

    it 'starts a RestartScheduler with the singleton store and a configured-miners proc' do
      server.send(:start_restart_scheduler)
      scheduler = server.instance_variable_get(:@restart_scheduler)
      expect(scheduler).to be_a(CgminerManager::RestartScheduler)
      expect(scheduler.thread).not_to be_nil

      server.send(:stop_restart_scheduler)
      expect(scheduler.thread.alive?).to be(false)
    end

    it 'is a no-op when restart_scheduler_enabled is false' do
      allow(config).to receive(:restart_scheduler_enabled).and_return(false)
      server.send(:start_restart_scheduler)
      expect(server.instance_variable_get(:@restart_scheduler)).to be_nil
    end
  end
end
