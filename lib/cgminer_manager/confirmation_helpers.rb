# frozen_string_literal: true

require 'securerandom'
require 'json'

module CgminerManager
  # Sinatra-mixin module wired into HttpApp. Provides the route-side
  # glue for the v1.7.0 two-step destructive-command confirmation flow:
  #
  #   start_or_dispatch_destructive(...)
  #     called from each gate-eligible route handler. If REQUIRE_CONFIRM
  #     is on AND the request didn't pass ?auto_confirm=1, generates a
  #     UUID v4 token, stores a ConfirmationStore::Entry, emits
  #     admin.action_started, and HALTs with 202 + content-negotiated
  #     pending-body. Otherwise yields to the caller's existing dispatch
  #     block (single-step path, identical to pre-1.7.0 behavior).
  #
  #   consume_confirmation_or_halt(token)
  #     called from POST /manager/admin/confirm/:token. Atomically
  #     consumes the token (session-bound); HALTs with 410/403 + an
  #     admin.action_rejected log emit on any failure mode. Returns the
  #     ConfirmationStore::Entry on success so the caller can dispatch.
  module ConfirmationHelpers # rubocop:disable Metrics/ModuleLength
    CONFIRMATION_TTL_SECONDS = 120 # 2 minutes — decision #5

    # Read-only typed verbs that NEVER gate (decision #4). Mirrors
    # ALLOWED_ADMIN_QUERIES on HttpApp; duplicated here to keep the
    # gate decision local to the helper.
    READ_ONLY_TYPED_COMMANDS = %w[version stats devs].freeze

    def start_or_dispatch_destructive(route_kind:, command:, scope:, args: nil)
      # Per-deployment opt-out (decision #1).
      return yield unless settings.confirmation_required

      # Fail-closed alignment check (decision #16): destructive POSTs
      # under AUTH=off + REQUIRE_CONFIRM=on refuse to issue tokens.
      if confirmation_auth_misaligned?
        halt 503, 'admin confirmation requires admin auth: ' \
                  'set CGMINER_MANAGER_ADMIN_AUTH back on, or set ' \
                  'CGMINER_MANAGER_REQUIRE_CONFIRM=off if you accept the dev-mode risk'
      end

      # Per-request escape hatch (decision #2).
      if params[:auto_confirm].to_s == '1'
        Logger.info(**AdminLogging.action_auto_confirmed_log_entry(
          command: command, scope: scope,
          request_id: confirmation_request_id,
          session_id_hash: confirmation_session_id_hash,
          remote_ip: request.ip, user_agent: request.user_agent,
          user: confirmation_user
        ))
        return yield
      end

      issue_confirmation_token(route_kind: route_kind, command: command,
                               scope: scope, args: args)
    end

    def consume_confirmation_or_halt(token)
      result = settings.confirmation_store.consume(token, confirmation_session_id_hash)
      return result if result.is_a?(ConfirmationStore::Entry)

      reject_confirmation!(token: token, reason: result)
    end

    private

    def issue_confirmation_token(route_kind:, command:, scope:, args:)
      now        = Time.now.utc
      token      = SecureRandom.uuid
      expires_at = now + CONFIRMATION_TTL_SECONDS
      entry = ConfirmationStore::Entry.new(
        token: token, command: command, scope: scope, args: args,
        route_kind: route_kind,
        request_id: confirmation_request_id,
        user: confirmation_user,
        session_id_hash: confirmation_session_id_hash,
        created_at: now, expires_at: expires_at
      )
      evicted = settings.confirmation_store.put(entry)
      log_eviction(evicted) if evicted

      Logger.info(**AdminLogging.action_started_log_entry(
        token: token, expires_at: expires_at,
        command: command, scope: scope,
        request_id: confirmation_request_id,
        session_id_hash: confirmation_session_id_hash,
        remote_ip: request.ip, user_agent: request.user_agent,
        user: confirmation_user,
        route_kind: route_kind, args: args
      ))

      halt 202, confirmation_pending_body(entry)
    end

    def reject_confirmation!(token:, reason:)
      Logger.warn(**AdminLogging.action_rejected_log_entry(
        reason: reason, token: token,
        request_id: confirmation_request_id,
        session_id_hash: confirmation_session_id_hash,
        user: confirmation_user
      ))
      reason == :session_mismatch ? halt(403, 'forbidden') : halt(410, 'gone')
    end

    def log_eviction(entry)
      age_ms = ((Time.now.utc - entry.created_at) * 1000).round
      Logger.warn(**AdminLogging.action_rejected_log_entry(
        reason: :evicted, token: entry.token,
        command: entry.command, scope: entry.scope,
        request_id: entry.request_id,
        session_id_hash: entry.session_id_hash,
        user: entry.user
      ), age_ms: age_ms)
    end

    def confirmation_pending_body(entry)
      if request.preferred_type(%w[application/json text/html]) == 'application/json'
        content_type :json
        JSON.generate(
          status: 'pending_confirmation',
          confirmation_token: entry.token,
          expires_at: entry.expires_at.utc.iso8601(3),
          command: entry.command, scope: entry.scope,
          confirm_url: "/manager/admin/confirm/#{entry.token}"
        )
      else
        @pending_entry = entry
        haml :'manager/confirm_pending', layout: false
      end
    end

    def confirmation_request_id
      env['cgminer_manager.request_id'] || request.env['HTTP_X_CGMINER_REQUEST_ID']
    end

    def confirmation_user
      env['cgminer_manager.admin_user']
    end

    # Binds a token to the originating identity for replay protection.
    # Two paths:
    #   * Basic Auth (curl, CI smoke, Slack-bot, etc.): each request
    #     ships the same auth header, so admin_user is stable across
    #     step 1 and step 2. Use it.
    #   * Session-cookie (browser admin tab): rack session carries
    #     across requests, so session_id_hash is stable.
    # Tagged so consume() can compare like-with-like (the AdminAuth
    # middleware doesn't establish a session for Basic Auth bypass,
    # which would otherwise cause every Basic-Auth pair of requests
    # to look like a session_mismatch).
    def confirmation_session_id_hash
      if confirmation_user
        "user:#{AdminLogging.session_id_hash(confirmation_user)}"
      else
        "session:#{AdminLogging.session_id_hash(session.id || session)}"
      end
    end

    # Decision #16: AUTH=off neuters session-binding (no real
    # session_id_hash). Routes refuse to issue tokens in that posture
    # — fail-closed. Detected by the AdminAuth middleware NOT setting
    # `cgminer_manager.admin_authed` (which it does on basic-auth
    # success) AND the env var being explicitly off.
    def confirmation_auth_misaligned?
      ENV['CGMINER_MANAGER_ADMIN_AUTH'] == 'off' &&
        !env['cgminer_manager.admin_authed']
    end
  end
end
