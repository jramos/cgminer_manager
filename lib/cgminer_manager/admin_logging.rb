# frozen_string_literal: true

require 'digest'

module CgminerManager
  # Pure helpers for the admin-surface plumbing: session-id hashing and
  # structured-log-entry construction. HttpApp still owns the
  # Sinatra-scoped decisions — `dispatch_pool_action` stays there because
  # it reads `params[:url]/:user/:pass` on the `add` branch and `halt`s
  # on unknown actions; `render_admin_result` stays there because it
  # renders haml.
  module AdminLogging # rubocop:disable Metrics/ModuleLength
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

    # ----- Two-step confirmation flow events (v1.7.0+) -----
    #
    # New audit events for the destructive-command confirmation flow:
    # admin.action_started, admin.action_confirmed,
    # admin.action_auto_confirmed, admin.action_cancelled, and
    # admin.action_rejected (single event with reason: discriminator
    # for :expired / :session_mismatch / :evicted / :not_found).
    #
    # Standard keys: confirmation_token (v4 UUID), expires_at (ISO8601),
    # started_age_ms (only on _confirmed), reason (Symbol, only on
    # _rejected). Cross-repo schema reservation lives in
    # cgminer_monitor's docs/log_schema.md.

    def action_started_log_entry(token:, expires_at:, command:, scope:, request_id:, # rubocop:disable Metrics/ParameterLists
                                 session_id_hash:, remote_ip:, user_agent:, user: nil,
                                 route_kind: nil, args: nil)
      {
        event: 'admin.action_started',
        request_id: request_id,
        confirmation_token: token,
        expires_at: expires_at.utc.iso8601(3),
        command: command,
        scope: scope,
        user: user,
        remote_ip: remote_ip,
        user_agent: user_agent,
        session_id_hash: session_id_hash,
        args: redact_args(route_kind: route_kind, command: command, args: args)
      }
    end

    def action_confirmed_log_entry(token:, command:, scope:, request_id:, # rubocop:disable Metrics/ParameterLists
                                   session_id_hash:, remote_ip:, user_agent:,
                                   started_age_ms:, user: nil, route_kind: nil, args: nil)
      {
        event: 'admin.action_confirmed',
        request_id: request_id,
        confirmation_token: token,
        command: command,
        scope: scope,
        user: user,
        remote_ip: remote_ip,
        user_agent: user_agent,
        session_id_hash: session_id_hash,
        started_age_ms: started_age_ms,
        args: redact_args(route_kind: route_kind, command: command, args: args)
      }
    end

    def action_auto_confirmed_log_entry(command:, scope:, request_id:, session_id_hash:, # rubocop:disable Metrics/ParameterLists
                                        remote_ip:, user_agent:, user: nil)
      {
        event: 'admin.action_auto_confirmed',
        request_id: request_id,
        command: command,
        scope: scope,
        user: user,
        remote_ip: remote_ip,
        user_agent: user_agent,
        session_id_hash: session_id_hash
      }
    end

    def action_cancelled_log_entry(token:, command:, scope:, request_id:, session_id_hash:, # rubocop:disable Metrics/ParameterLists
                                   user: nil)
      {
        event: 'admin.action_cancelled',
        request_id: request_id,
        confirmation_token: token,
        command: command,
        scope: scope,
        user: user,
        session_id_hash: session_id_hash
      }
    end

    def action_rejected_log_entry(reason:, token:, request_id:, session_id_hash:, # rubocop:disable Metrics/ParameterLists
                                  command: nil, scope: nil, user: nil)
      {
        event: 'admin.action_rejected',
        request_id: request_id,
        confirmation_token: token,
        reason: reason,
        command: command,
        scope: scope,
        user: user,
        session_id_hash: session_id_hash
      }
    end

    # Decision #18: pool_management/add carries credential args (URL,
    # user, pass) and must NEVER hit the audit log. Raw run args are
    # operator-supplied opaque strings — passed through (operator is
    # on the hook for what they typed). Typed-command writes have no
    # args. Returns nil for nil input so empty payloads stay empty.
    def redact_args(route_kind:, command:, args:)
      return nil if args.nil?
      return '[REDACTED: pool credentials]' if route_kind == :manage_pools && command.to_s == 'add'

      args
    end

    # ----- Drain mode events (v1.8.0+) -----
    #
    # Four collapsed audit events for the per-miner Drain / Resume
    # flow. Three of them carry a `cause:` Symbol discriminator
    # (:drain / :resume / :auto_resume; drain.resumed also accepts
    # :operator and :auto_resume_orphan_cleared) so the originating
    # caller is grep-discriminable without proliferating event names.
    # cgminer_monitor v1.5.0+'s docs/log_schema.md catalogs them.

    def drain_applied_log_entry(miner_id:, drained_at:, auto_resume_seconds:, request_id:, # rubocop:disable Metrics/ParameterLists
                                user: nil, pool_index: 0)
      {
        event: 'drain.applied',
        request_id: request_id,
        miner_id: miner_id,
        user: user,
        drained_at: drained_at,
        auto_resume_seconds: auto_resume_seconds,
        pool_index: pool_index
      }
    end

    def drain_resumed_log_entry(miner_id:, cause:, drained_at:, request_id: nil, # rubocop:disable Metrics/ParameterLists
                                user: nil, pool_index: 0)
      {
        event: 'drain.resumed',
        request_id: request_id,
        miner_id: miner_id,
        user: user,
        cause: cause,
        drained_at: drained_at,
        pool_index: pool_index
      }
    end

    def drain_failed_log_entry(miner_id:, cause:, error:, code:, request_id: nil, # rubocop:disable Metrics/ParameterLists
                               user: nil, attempt_count: nil)
      {
        event: 'drain.failed',
        request_id: request_id,
        miner_id: miner_id,
        user: user,
        cause: cause,
        error: error,
        code: code,
        attempt_count: attempt_count
      }
    end

    def drain_indeterminate_log_entry(miner_id:, cause:, request_id: nil,
                                      user: nil, pool_index: 0)
      {
        event: 'drain.indeterminate',
        request_id: request_id,
        miner_id: miner_id,
        user: user,
        cause: cause,
        pool_index: pool_index
      }
    end
  end
end
