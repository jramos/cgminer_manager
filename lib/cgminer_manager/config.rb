# frozen_string_literal: true

require 'yaml'
require 'securerandom'
require 'ipaddr'

module CgminerManager
  Config = Data.define(
    :monitor_url,
    :miners_file,
    :port, :bind,
    :log_format, :log_level,
    :session_secret,
    :stale_threshold_seconds,
    :shutdown_timeout,
    :monitor_timeout,
    :pool_thread_cap,
    :pid_file,
    :rate_limit_enabled,
    :rate_limit_requests,
    :rate_limit_window_seconds,
    :trusted_proxies,
    :restart_schedules_file,
    :restart_scheduler_enabled,
    :rack_env
  ) do
    def validate!
      raise ConfigError, 'CGMINER_MONITOR_URL is required' if monitor_url.nil? || monitor_url.empty?
      raise ConfigError, "miners_file not found: #{miners_file}" unless File.exist?(miners_file)
      raise ConfigError, 'log_format must be json or text' unless %w[json text].include?(log_format)
      raise ConfigError, 'invalid log_level' unless %w[debug info warn error].include?(log_level)

      self
    end

    def load_miners
      YAML.safe_load_file(miners_file).map { |m| [m['host'], m['port'] || 4028] }
    end

    def production?
      rack_env == 'production'
    end
  end

  class << Config
    def from_env(env = ENV)
      rack_env = env.fetch('RACK_ENV', 'development')
      validate_admin_auth!(env)
      new(
        monitor_url: env['CGMINER_MONITOR_URL'],
        miners_file: env.fetch('MINERS_FILE', 'config/miners.yml'),
        port: parse_int(env, 'PORT', '3000'),
        bind: env.fetch('BIND', '127.0.0.1'),
        log_format: env.fetch('LOG_FORMAT', rack_env == 'production' ? 'json' : 'text'),
        log_level: env.fetch('LOG_LEVEL', 'info'),
        session_secret: resolve_session_secret(env, rack_env),
        stale_threshold_seconds: parse_int(env, 'STALE_THRESHOLD_SECONDS', '300'),
        shutdown_timeout: parse_int(env, 'SHUTDOWN_TIMEOUT', '10'),
        monitor_timeout: parse_int(env, 'MONITOR_TIMEOUT_MS', '2000'),
        pool_thread_cap: parse_int(env, 'POOL_THREAD_CAP', '8'),
        pid_file: env['CGMINER_MANAGER_PID_FILE'],
        rate_limit_enabled: env['CGMINER_MANAGER_RATE_LIMIT'] != 'off',
        rate_limit_requests: parse_int(env, 'CGMINER_MANAGER_RATE_LIMIT_REQUESTS', '60'),
        rate_limit_window_seconds: parse_int(env, 'CGMINER_MANAGER_RATE_LIMIT_WINDOW_SECONDS', '60'),
        trusted_proxies: parse_cidr_list(env, 'CGMINER_MANAGER_TRUSTED_PROXIES'),
        restart_schedules_file: env.fetch('CGMINER_MANAGER_RESTART_SCHEDULES_FILE',
                                          'data/restart_schedules.json'),
        restart_scheduler_enabled: env['CGMINER_MANAGER_RESTART_SCHEDULER'] != 'off',
        rack_env: rack_env
      ).validate!
    end

    private

    # Admin auth is required by default as of 1.3.0. Creds are
    # deliberately not a Config field — AdminAuth reads them
    # per-request so tests/dev can toggle without restart. This
    # boot-time check only asserts the posture is configured; the
    # runtime middleware still handles post-boot ENV mutation.
    #
    # Boot accepts `=off` regardless of creds (short-circuits on the
    # first line). Runtime (AdminAuth#call) only honors `=off` when
    # creds are unset — creds-set wins at request time. Intentional
    # asymmetry: boot's job is "posture is configured," runtime's job
    # is "don't let a stale hatch bypass rotated creds."
    def validate_admin_auth!(env)
      return if env['CGMINER_MANAGER_ADMIN_AUTH'] == 'off'

      user = env['CGMINER_MANAGER_ADMIN_USER'].to_s
      pass = env['CGMINER_MANAGER_ADMIN_PASSWORD'].to_s
      return unless user.empty? || pass.empty?

      raise ConfigError,
            'admin auth is required by default: set CGMINER_MANAGER_ADMIN_USER + ' \
            'CGMINER_MANAGER_ADMIN_PASSWORD, or CGMINER_MANAGER_ADMIN_AUTH=off to ' \
            'deliberately disable (see MIGRATION.md)'
    end

    def parse_int(env, key, default)
      Integer(env.fetch(key, default))
    rescue ArgumentError
      raise ConfigError, "#{key} must be an integer, got: #{env[key].inspect}"
    end

    def parse_cidr_list(env, key)
      raw = env[key]
      return [] if raw.nil? || raw.strip.empty?

      raw.split(',').map(&:strip).reject(&:empty?).map do |cidr|
        IPAddr.new(cidr)
      rescue IPAddr::Error => e
        raise ConfigError, "#{key} contains invalid CIDR '#{cidr}': #{e.message}"
      end
    end

    def resolve_session_secret(env, rack_env)
      secret = env['SESSION_SECRET']
      return secret if secret && !secret.empty?
      raise ConfigError, 'SESSION_SECRET is required in production' if rack_env == 'production'

      warn '[cgminer_manager] SESSION_SECRET unset; generating ephemeral secret (dev only)'
      SecureRandom.hex(32)
    end
  end
end
