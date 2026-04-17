# frozen_string_literal: true

require 'rack/auth/basic'
require 'rack/protection/authenticity_token'

module CgminerManager
  # Opt-in HTTP Basic Auth for admin routes. When the env vars
  # CGMINER_MANAGER_ADMIN_USER and CGMINER_MANAGER_ADMIN_PASSWORD are both
  # set (non-empty), admin POSTs require matching Basic Auth credentials.
  # On successful auth, marks env['cgminer_manager.admin_authed'] so the
  # downstream CSRF middleware can skip (a valid static credential is
  # strictly stronger proof than a session cookie + CSRF token, and this
  # lets operators curl admin routes during incidents).
  #
  # Admin configuration is read per-request via ENV rather than frozen at
  # boot so tests and dev harnesses can toggle the gate without restart.
  # Empty strings are treated as unset.
  #
  # On failed auth: 401 with WWW-Authenticate, plus a structured
  # admin.auth_failed log event.
  class AdminAuth
    ADMIN_PATH = %r{\A/(manager|miner/[^/]+)/admin(/|\z)}

    def initialize(app)
      @app = app
    end

    def call(env)
      request = Rack::Request.new(env)
      return @app.call(env) unless ADMIN_PATH.match?(request.path_info)
      return @app.call(env) unless configured?

      auth = Rack::Auth::Basic::Request.new(env)
      if auth.provided? && auth.basic? && valid?(auth.credentials)
        env['cgminer_manager.admin_authed'] = true
        env['cgminer_manager.admin_user']   = auth.credentials.first
        return @app.call(env)
      end

      log_failure(request, reason_for(auth))
      unauthorized
    end

    private

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
