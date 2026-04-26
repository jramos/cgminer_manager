# frozen_string_literal: true

module CgminerManager
  # In-process Mutex+Hash store for pending two-step confirmation tokens
  # on destructive admin commands. Same posture as RateLimiter:
  # process-local, single-Puma-process safe; cluster-mode worker-hop loses
  # tokens (boot-time warn surfaces this in Config). Lazy expiry on read,
  # MAX_PENDING-bounded eviction by oldest created_at.
  #
  # Sentinel symbols rather than nil for failure modes so the caller can
  # log a structured `reason:` on the new admin.action_rejected event:
  # `:not_found` (token never existed or already consumed),
  # `:session_mismatch` (the confirming request's session_id_hash differs
  # from the issuing one), `:expired` (TTL elapsed). Successful consume
  # returns the Entry verbatim.
  class ConfirmationStore
    Entry = Data.define(
      :token, :command, :scope, :args, :route_kind,
      :request_id, :user, :session_id_hash,
      :created_at, :expires_at
    )

    MAX_PENDING = 1024

    # `clock:` is an optional callable returning the current Time;
    # injected by specs so they can advance time without sleeping.
    # nil → real `Time.now.utc`.
    def initialize(clock: nil)
      @entries = {}
      @mutex   = Mutex.new
      @clock   = clock
    end

    # Inserts the entry. If MAX_PENDING is now exceeded, evicts the
    # oldest entry by created_at and returns it (caller logs an
    # admin.action_rejected reason: :evicted). Otherwise returns nil.
    def put(entry)
      @mutex.synchronize do
        @entries[entry.token] = entry
        return nil if @entries.size <= MAX_PENDING

        oldest_token = @entries.min_by { |_, e| e.created_at }.first
        @entries.delete(oldest_token)
      end
    end

    # Atomically validates session + expiry and removes the entry on
    # success. Returns the Entry, :not_found, :session_mismatch, or
    # :expired. Session mismatch is reported ahead of expiry so a
    # cross-session attacker can't probe whether a token is alive.
    def consume(token, session_id_hash)
      @mutex.synchronize do
        entry = @entries[token]
        return :not_found if entry.nil?
        return :session_mismatch if entry.session_id_hash != session_id_hash

        if entry.expires_at < current_time
          @entries.delete(token)
          return :expired
        end

        @entries.delete(token)
        entry
      end
    end

    # Read without consuming. Used by the JS-off fallback partial that
    # renders inside the 202 response body — needs the entry's command
    # + scope to display them, but the operator still has to POST the
    # confirm endpoint to dispatch. Caller is responsible for any
    # expiry semantics on the rendered page; expiry is ONLY enforced
    # by #consume.
    def peek(token)
      @mutex.synchronize { @entries[token] }
    end

    # Explicit cancel from the modal's Cancel button or the JS-off
    # form's DELETE submission. Returns the removed Entry,
    # :session_mismatch, or :not_found.
    def cancel(token, session_id_hash)
      @mutex.synchronize do
        entry = @entries[token]
        return :not_found if entry.nil?
        return :session_mismatch if entry.session_id_hash != session_id_hash

        @entries.delete(token)
        entry
      end
    end

    # Sweeps and returns expired entries. Not invoked from a thread —
    # call sites do their own expiry on consume; this is for an
    # operator-driven cleanup (or future periodic sweep job).
    def purge_expired!
      now = current_time
      @mutex.synchronize do
        expired = @entries.values.select { |e| e.expires_at < now }
        expired.each { |e| @entries.delete(e.token) }
        expired
      end
    end

    private

    def current_time
      @clock ? @clock.call : Time.now.utc
    end
  end
end
