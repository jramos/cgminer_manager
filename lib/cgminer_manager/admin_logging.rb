# frozen_string_literal: true

require 'digest'

module CgminerManager
  # Pure helpers for the admin-surface plumbing: session-id hashing and
  # structured-log-entry construction. HttpApp still owns the
  # Sinatra-scoped decisions — `dispatch_pool_action` stays there because
  # it reads `params[:url]/:user/:pass` on the `add` branch and `halt`s
  # on unknown actions; `render_admin_result` stays there because it
  # renders haml.
  module AdminLogging
    module_function

    def session_id_hash(sid)
      Digest::SHA256.hexdigest(sid.to_s)[0..11]
    end

    # Mirrors the pre-extraction shape at http_app.rb: fixed keys first,
    # **extra merged in last, so callers that pass `args:` / other
    # context through `log_admin_command(..., args: ...)` still surface
    # those in the emitted log entry.
    def command_log_entry(event:, command:, scope:, request_id:, session_id_hash:, # rubocop:disable Metrics/ParameterLists
                          remote_ip:, user_agent:, user: nil, **extra)
      {
        event: event,
        request_id: request_id,
        user: user,
        remote_ip: remote_ip,
        user_agent: user_agent,
        session_id_hash: session_id_hash,
        command: command,
        scope: scope
      }.merge(extra)
    end

    def result_log_entry(command:, scope:, result:, started_at:, request_id:)
      {
        event: 'admin.result',
        request_id: request_id,
        command: command,
        scope: scope,
        ok_count: result.ok_count,
        failed_count: result.failed_count,
        failed_codes: result.failed_codes_count_map,
        duration_ms: ((Time.now - started_at) * 1000).round
      }
    end

    # Mirror of CgminerMonitor::Poller#code_for. Six-symbol vocabulary
    # documented in cgminer_monitor's docs/log_schema.md `code`
    # standard-key row. Branch ordering: ApiError-shaped errors win
    # via the duck-typed #code Symbol guard (covers the AccessDeniedError
    # subclass too); transport-only errors fall through to the
    # synthesized values.
    def code_for(error)
      return error.code if error.respond_to?(:code) && error.code.is_a?(Symbol)
      return :timeout if error.is_a?(CgminerApiClient::TimeoutError)
      return :connection_error if error.is_a?(CgminerApiClient::ConnectionError)

      :unexpected
    end
  end
end
