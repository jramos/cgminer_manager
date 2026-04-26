# frozen_string_literal: true

require 'securerandom'

module CgminerManager
  # Rack middleware that extracts X-Cgminer-Request-Id from the inbound
  # request, falls back to a freshly generated UUID v4 when absent, and
  # stashes the value on env['cgminer_manager.request_id'] for downstream
  # access (Sinatra before-filters, route handlers, AdminAuth, RateLimiter,
  # MonitorClient outbound calls, FleetBuilders' on_wire closure). Always
  # echoes the value as a response header so callers can correlate without
  # parsing structured logs.
  #
  # Sits at the top of the middleware stack — above RateLimiter and
  # AdminAuth — so rate_limit.exceeded and admin.auth_failed events
  # can include request_id even when the request never reaches a
  # Sinatra before-filter.
  #
  # Malformed inbound values pass through unchanged; validation would
  # force operators to debug header rewrites at load balancers and adds
  # nothing because dispatch is on string equality, not UUID semantics.
  # Mirrors CgminerMonitor::RequestId.
  class RequestId
    HEADER = 'X-Cgminer-Request-Id'
    ENV_KEY = 'cgminer_manager.request_id'
    RACK_HEADER_KEY = 'HTTP_X_CGMINER_REQUEST_ID'

    def initialize(app)
      @app = app
    end

    def call(env)
      request_id = env[RACK_HEADER_KEY] || SecureRandom.uuid
      env[ENV_KEY] = request_id
      status, headers, body = @app.call(env)
      headers[HEADER] = request_id
      [status, headers, body]
    end
  end
end
