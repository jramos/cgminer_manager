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

  let(:config) do
    instance_double(
      CgminerManager::Config,
      monitor_url: 'http://monitor:9292',
      miners_file: miners_file,
      stale_threshold_seconds: 300,
      pool_thread_cap: 8,
      monitor_timeout: 2500,
      session_secret: 'a' * 64,
      production?: false
    )
  end

  before do
    # Reset HttpApp settings to known state so ordering across examples
    # doesn't muddy the assertions.
    CgminerManager::HttpApp.set :monitor_url,             nil
    CgminerManager::HttpApp.set :miners_file,             nil
    CgminerManager::HttpApp.set :configured_miners,       nil
    CgminerManager::HttpApp.set :stale_threshold_seconds, 300
    CgminerManager::HttpApp.set :pool_thread_cap,         8
    CgminerManager::HttpApp.set :monitor_timeout_ms,      2000
    CgminerManager::HttpApp.set :session_secret,          nil
    CgminerManager::HttpApp.set :production,              false
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
  end
end
