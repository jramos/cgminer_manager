# frozen_string_literal: true

require 'puma'
require 'puma/configuration'
require 'puma/launcher'
require 'rack'

module CgminerManager
  class Server
    def initialize(config)
      @config  = config
      @signals = Queue.new
    end

    def run
      install_signal_handlers
      configure_http_app
      Logger.info(event: 'server.start', pid: Process.pid,
                  bind: @config.bind, port: @config.port)

      @booted = Queue.new
      launcher    = build_puma_launcher
      puma_thread = start_puma_thread(launcher)

      # Puma's setup_signals runs on its thread during launcher.run and
      # overwrites any traps we installed earlier. Wait for Puma to
      # finish booting (signals already installed, listener bound)
      # before reinstalling ours so signals land back in our @signals
      # queue. Covers SIGHUP too — Puma's default HUP handler calls
      # stop() when stdout_redirect is unset, which would shut us down
      # instead of triggering a reload.
      @booted.pop
      install_signal_handlers

      write_pid_file

      dispatch_signals_until_stop
      Logger.info(event: 'server.stopping')

      launcher.stop
      puma_thread.join(@config.shutdown_timeout)
      Logger.info(event: 'server.stopped')
      0
    ensure
      unlink_pid_file
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
      # Wire the session + auth + CSRF middleware AFTER settings are
      # populated — otherwise `use Rack::Session::Cookie, secret: ...`
      # would freeze a nil/random secret before the operator's
      # CGMINER_MANAGER_SESSION_SECRET ever reached the middleware.
      HttpApp.install_middleware!
    end

    def start_puma_thread(launcher)
      Thread.new do
        launcher.run
      rescue Exception => e # rubocop:disable Lint/RescueException
        Logger.error(event: 'puma.crash', error: e.class.to_s,
                     message: e.message, backtrace: e.backtrace&.first(10))
        @booted << true # unblock main if we died before booting
        @signals << :stop
      end
    end

    def install_signal_handlers
      Signal.trap('INT')  { @signals << :stop }
      Signal.trap('TERM') { @signals << :stop }
      Signal.trap('HUP')  { @signals << :reload }
    end

    def dispatch_signals_until_stop
      loop do
        case @signals.pop
        when :reload then perform_reload
        when :stop   then break
        end
      end
    end

    # Single-swap reload: HttpApp holds the only live reference to the
    # miner list. No partial-failure window — either the new list
    # parses and lands, or it doesn't and the old list stays.
    def perform_reload
      Logger.info(event: 'reload.signal_received')
      count = HttpApp.reload_miners!
      Logger.info(event: 'reload.ok', miners: count) if count
    end

    def write_pid_file
      return unless @config.pid_file

      File.write(@config.pid_file, "#{Process.pid}\n")
      Logger.info(event: 'server.pid_file_written', path: @config.pid_file)
    end

    def unlink_pid_file
      return unless @config.pid_file

      File.unlink(@config.pid_file)
    rescue Errno::ENOENT
      # already gone — shutdown raced with external cleanup; fine
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
