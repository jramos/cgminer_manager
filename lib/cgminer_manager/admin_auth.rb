# frozen_string_literal: true

require 'rack/auth/basic'
require 'rack/protection/authenticity_token'

module CgminerManager
  # HTTP Basic Auth for admin routes. Required by default as of 1.3.0:
  # `Config.from_env` raises `ConfigError` at boot unless both
  # `CGMINER_MANAGER_ADMIN_USER` and `CGMINER_MANAGER_ADMIN_PASSWORD` are
  # set, or the operator opts into the open-admin posture with
  # `CGMINER_MANAGER_ADMIN_AUTH=off`.
  #
  # Runtime dispatch (defense-in-depth for post-boot env tampering):
  # - Creds set → Basic Auth required. On success marks
  #   `env['cgminer_manager.admin_authed']` so CSRF bypass fires.
  # - Creds unset AND `CGMINER_MANAGER_ADMIN_AUTH=off` → pass through.
  # - Creds unset AND no escape hatch → 503 + `admin.auth_misconfigured`.
  #
  # Precedence: the escape hatch only fires when creds are unset. If
  # creds are set, the gate engages regardless of `=off` — rotating
  # creds can't accidentally slip through a leftover `=off`.
  #
  # Admin configuration is read per-request via ENV rather than frozen
  # at boot so tests and dev harnesses can toggle the gate without
  # restart. Empty strings are treated as unset.
  class AdminAuth
    ADMIN_PATH = %r{\A/(manager|miner/[^/]+)/admin(/|\z)}

    def initialize(app)
      @app = app
    end

    def call(env)
      request = Rack::Request.new(env)
      return @app.call(env) unless ADMIN_PATH.match?(request.path_info)
      return @app.call(env) if auth_disabled? && !configured?
      return misconfigured(request) unless configured?

      authenticate(env, request)
    end

    private

    def authenticate(env, request)
      auth = Rack::Auth::Basic::Request.new(env)
      if auth.provided? && auth.basic? && valid?(auth.credentials)
        env['cgminer_manager.admin_authed'] = true
        env['cgminer_manager.admin_user']   = auth.credentials.first
        return @app.call(env)
      end

      log_failure(request, reason_for(auth))
      unauthorized
    end

    def auth_disabled?
      ENV.fetch('CGMINER_MANAGER_ADMIN_AUTH', '') == 'off'
    end

    def configured?
      !admin_user.empty? && !admin_password.empty?
    end

    def admin_user
      ENV.fetch('CGMINER_MANAGER_ADMIN_USER', '').to_s
    end

    def admin_password
      ENV.fetch('CGMINER_MANAGER_ADMIN_PASSWORD', '').to_s
    end

    def valid?(credentials)
      user, pass = credentials
      return false unless user == admin_user

      Rack::Utils.secure_compare(pass.to_s, admin_password)
    end

    def reason_for(auth)
      return :missing_creds unless auth.provided? && auth.basic?

      user, = auth.credentials
      user == admin_user ? :bad_creds : :user_mismatch
    end

    def log_failure(request, reason)
      Logger.warn(event: 'admin.auth_failed',
                  reason: reason,
                  path: request.path_info,
                  remote_ip: request.ip,
                  user_agent: request.user_agent)
    end

    def unauthorized
      [401,
       { 'Content-Type' => 'text/plain',
         'WWW-Authenticate' => 'Basic realm="cgminer_manager admin"' },
       ["Admin authentication required\n"]]
    end

    def misconfigured(request)
      Logger.warn(event: 'admin.auth_misconfigured',
                  path: request.path_info,
                  remote_ip: request.ip,
                  user_agent: request.user_agent)
      body = 'admin authentication is misconfigured: set ' \
             'CGMINER_MANAGER_ADMIN_USER + CGMINER_MANAGER_ADMIN_PASSWORD, ' \
             "or CGMINER_MANAGER_ADMIN_AUTH=off to disable (see MIGRATION.md)\n"
      # Deliberately no WWW-Authenticate header: this is a server-config
      # failure, not an auth challenge. Prompting a browser for creds it
      # can't produce would just loop.
      [503, { 'Content-Type' => 'text/plain' }, [body]]
    end
  end

  # Short-circuit Rack::Protection::AuthenticityToken when admin Basic Auth
  # already authenticated the request. Applied only to the request; CSRF
  # protection still runs for every non-admin route and for admin routes
  # accessed without Basic Auth (the browser path, which also needs CSRF).
  class ConditionalAuthenticityToken < Rack::Protection::AuthenticityToken
    def call(env)
      return @app.call(env) if env['cgminer_manager.admin_authed']

      super
    end
  end
end
