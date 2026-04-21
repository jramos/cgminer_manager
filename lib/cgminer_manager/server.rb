# frozen_string_literal: true

require 'puma'
require 'puma/configuration'
require 'puma/launcher'
require 'rack'

module CgminerManager
  class Server
    def initialize(config)
      @config = config
      @stop   = Queue.new
    end

    def run
      install_signal_handlers
      configure_http_app
      Logger.info(event: 'server.start', pid: Process.pid,
                  bind: @config.bind, port: @config.port)

      @booted = Queue.new
      launcher = build_puma_launcher
      puma_thread = start_puma_thread(launcher)

      # Puma's setup_signals runs on its thread during launcher.run and
      # overwrites any SIGTERM/SIGINT traps we installed earlier. Wait for
      # Puma to finish booting (signals already installed, listener already
      # bound) before reinstalling ours so signals land back in our @stop
      # queue.
      @booted.pop
      install_signal_handlers

      signal = @stop.pop
      Logger.info(event: 'server.stopping', signal: signal)

      launcher.stop
      puma_thread.join(@config.shutdown_timeout)
      Logger.info(event: 'server.stopped')
      0
    end

    private

    def configure_http_app
      HttpApp.set :monitor_url,             @config.monitor_url
      HttpApp.set :miners_file,             @config.miners_file
      HttpApp.set :stale_threshold_seconds, @config.stale_threshold_seconds
      HttpApp.set :pool_thread_cap,         @config.pool_thread_cap
      HttpApp.set :monitor_timeout_ms,      @config.monitor_timeout
      HttpApp.set :session_secret,          @config.session_secret
      HttpApp.set :production,              @config.production?
      # Eagerly parse miners.yml so a malformed file surfaces as a
      # ConfigError at boot (CLI exit 2), not as an HTTP 500 on the first
      # request after Puma binds the listener.
      HttpApp.set :configured_miners,       HttpApp.parse_miners_file(@config.miners_file)
    end

    def start_puma_thread(launcher)
      Thread.new do
        launcher.run
      rescue Exception => e # rubocop:disable Lint/RescueException
        Logger.error(event: 'puma.crash', error: e.class.to_s, message: e.message)
        @booted << true # unblock main if we died before booting
        @stop << 'puma_crash'
      end
    end

    def install_signal_handlers
      %w[INT TERM].each { |s| trap(s) { @stop << s } }
    end

    def build_puma_launcher
      puma_config = Puma::Configuration.new do |user_config|
        user_config.bind("tcp://#{@config.bind}:#{@config.port}")
        user_config.threads(1, 8)
        user_config.environment(@config.rack_env)
        user_config.raise_exception_on_sigterm(false)
        user_config.app(Rack::Builder.new { run HttpApp.new }.to_app)
      end
      launcher = Puma::Launcher.new(puma_config, log_writer: Puma::LogWriter.null)
      booted = @booted
      launcher.events.on_booted { booted << true }
      launcher
    end
  end
end
