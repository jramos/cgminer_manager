# frozen_string_literal: true

require 'cgminer_api_client'

module CgminerManager
  # Background thread that walks RestartStore once every TICK_SECONDS and
  # fires `restart` against any miner whose UTC time-of-day is in its
  # window. Date-based dedupe (last_scheduled_date_utc) ensures each
  # schedule fires at most once per UTC calendar day.
  #
  # Designed to share a singleton RestartStore with HTTP request handlers
  # so that route POSTs and scheduler ticks see each other's writes
  # without contention. Server#configure_http_app is responsible for
  # building the store and stashing it under HttpApp.settings.restart_store.
  class RestartScheduler
    TICK_SECONDS    = 30
    WINDOW_MINUTES  = 2

    # Auto-resume backoff: attempts 2..N retry at min(60, 2^(N-1)) * 60
    # seconds since the last attempt, capped at 60 minutes. After this
    # many consecutive failures we emit drain.auto_resume_giving_up
    # once at error-level, then keep retrying at the cap with warn
    # emissions only — recoverable when the rig comes back.
    AUTO_RESUME_GIVING_UP_AFTER = 5

    def initialize(store:, configured_miners_provider:, # rubocop:disable Metrics/ParameterLists
                   auto_resume_seconds: 3600,
                   clock: -> { Time.now.utc },
                   miner_factory: ->(host, port) { CgminerApiClient::Miner.new(host, port) },
                   pool_manager_factory: ->(miner) { PoolManager.new([miner]) })
      @store                      = store
      @configured_miners_provider = configured_miners_provider
      @auto_resume_seconds        = auto_resume_seconds
      @clock                      = clock
      @miner_factory              = miner_factory
      @pool_manager_factory       = pool_manager_factory
      @stopped                    = false
      @mutex                      = Mutex.new
      @cv                         = ConditionVariable.new
      @thread                     = nil
    end

    attr_reader :thread

    def start
      return if @thread&.alive?

      @stopped = false
      @thread  = Thread.new { thread_main }
    end

    def stop
      @mutex.synchronize do
        @stopped = true
        @cv.signal
      end
    end

    def stopped?
      @stopped
    end

    def join(timeout = nil)
      @thread&.join(timeout)
    end

    # Run a single scheduling pass. Public so specs can drive ticks
    # synchronously without spawning the thread.
    #
    # The auto-resume pass runs FIRST so a drained schedule that has
    # aged out into its restart window correctly fires the restart in
    # the same tick: drain clears, schedule fires.
    def tick
      now           = @clock.call
      miners_by_id  = configured_miners_index

      auto_resume_drained(now, miners_by_id)

      @store.load.each_value do |schedule|
        process_schedule(schedule, now, miners_by_id)
      end
    end

    private

    # Walks the store for drained schedules whose backoff window has
    # elapsed. For each candidate, re-validates `drained == true` under
    # the store's mutex (protects against a concurrent operator Resume
    # winning the race) before issuing the wire call.
    def auto_resume_drained(now, miners_by_id)
      @store.load.each_value do |schedule|
        next unless schedule.draining?
        next unless auto_resume_due?(schedule, now)

        miner_id = schedule.miner_id
        host_port = miners_by_id[miner_id]
        next force_clear_orphan_drain(miner_id) if host_port.nil?

        attempt_auto_resume(miner_id, host_port, now)
      end
    end

    # Exposed for callers that need the same backoff cadence (the
    # scheduler's tick). `now - drained_at >= @auto_resume_seconds`
    # is the first-attempt gate; subsequent attempts back off at
    # min(60, 2^(N-1)) * 60 seconds since the last attempt.
    def auto_resume_due?(schedule, now)
      drained_at = parse_iso8601(schedule.drained_at)
      return false if drained_at.nil?
      return false unless (now - drained_at) >= @auto_resume_seconds

      last_attempt = parse_iso8601(schedule.auto_resume_last_attempt_at)
      return true if last_attempt.nil?

      backoff_seconds = [60, 2**[schedule.auto_resume_attempt_count - 1, 0].max].min * 60
      (now - last_attempt) >= backoff_seconds
    end

    def attempt_auto_resume(miner_id, host_port, now)
      pool_result = nil
      @store.update(miner_id) do |existing|
        next existing if existing.nil? || !existing.draining?

        host, port = host_port
        miner = @miner_factory.call(host, port)
        pool_result = @pool_manager_factory.call(miner).enable_pool(pool_index: 0)
        next_schedule_after_auto_resume(existing, pool_result, now)
      end

      log_auto_resume_outcome(miner_id, pool_result, now) if pool_result
    rescue StandardError => e
      Logger.error(event: 'drain.auto_resume_persist_failed',
                   miner_id: miner_id,
                   error: e.class.to_s, message: e.message)
    end

    def next_schedule_after_auto_resume(schedule, pool_result, now)
      status = pool_result_status(pool_result)
      case status
      when :ok, :indeterminate
        # Both success and indeterminate clear the drain state so the
        # next nightly restart can proceed; indeterminate operators
        # should verify rig state but the scheduler shouldn't keep
        # retrying a possibly-already-resumed rig.
        schedule.with(drained: false, drained_at: nil, drained_by: nil,
                      auto_resume_attempt_count: 0,
                      auto_resume_last_attempt_at: nil)
      else # :failed
        new_count = schedule.auto_resume_attempt_count + 1
        schedule.with(auto_resume_attempt_count: new_count,
                      auto_resume_last_attempt_at: now.iso8601(3))
      end
    end

    def log_auto_resume_outcome(miner_id, pool_result, now)
      status = pool_result_status(pool_result)
      schedule = @store.load[miner_id]
      attempt_count = schedule&.auto_resume_attempt_count || 0
      drained_at_iso = schedule&.drained_at # nil after :ok / :indeterminate clears

      case status
      when :ok
        Logger.info(event: 'drain.resumed', miner_id: miner_id,
                    cause: :auto_resume, drained_at: drained_at_iso, pool_index: 0)
      when :indeterminate
        Logger.warn(event: 'drain.indeterminate', miner_id: miner_id,
                    cause: :auto_resume, pool_index: 0)
      else # :failed
        log_payload = pool_failed_log_payload(pool_result)
        Logger.warn(event: 'drain.failed', miner_id: miner_id,
                    cause: :auto_resume, attempt_count: attempt_count, **log_payload)
        if attempt_count == AUTO_RESUME_GIVING_UP_AFTER
          Logger.error(event: 'drain.auto_resume_giving_up',
                       miner_id: miner_id, attempt_count: attempt_count)
        end
      end
      _ = now # accepted for symmetry; unused in current emissions
    end

    def force_clear_orphan_drain(miner_id)
      drained_at = nil
      @store.update(miner_id) do |existing|
        next existing if existing.nil? || !existing.draining?

        drained_at = existing.drained_at
        existing.with(drained: false, drained_at: nil, drained_by: nil,
                      auto_resume_attempt_count: 0,
                      auto_resume_last_attempt_at: nil)
      end
      Logger.info(event: 'drain.resumed', miner_id: miner_id,
                  cause: :auto_resume_orphan_cleared,
                  drained_at: drained_at, pool_index: 0)
    end

    def pool_result_status(pool_result)
      entries = pool_result.entries
      return :failed if entries.empty?
      return :failed if entries.any? { |e| e.command_status == :failed }
      return :indeterminate if entries.any? { |e| e.command_status == :indeterminate }

      :ok
    end

    def pool_failed_log_payload(pool_result)
      failed = pool_result.entries.find { |e| e.command_status == :failed }
      reason = failed&.command_reason.to_s
      { error: reason.empty? ? 'unknown' : reason, code: :unexpected }
    end

    def parse_iso8601(value)
      return nil unless value.is_a?(String)

      Time.iso8601(value)
    rescue ArgumentError
      nil
    end

    # Thread-top guard: any uncaught exception inside the loop would
    # silently kill the scheduler. Wrap with rescue Exception (mirroring
    # Server#start_puma_thread) so a NoMethodError or similar surfaces
    # in the logs as `restart.scheduler.crash` instead of vanishing.
    def thread_main
      until @stopped
        run_one_tick
        interruptible_sleep(TICK_SECONDS)
      end
    rescue Exception => e # rubocop:disable Lint/RescueException
      Logger.error(event: 'restart.scheduler.crash',
                   error: e.class.to_s, message: e.message,
                   backtrace: e.backtrace&.first(10))
    end

    def run_one_tick
      tick
    rescue StandardError => e
      Logger.error(event: 'restart.scheduler.tick_error',
                   error: e.class.to_s, message: e.message)
    end

    def process_schedule(schedule, now, miners_by_id)
      return unless schedule.enabled
      return if schedule.time_utc.nil?
      # Drained miners skip the nightly restart; auto-resume in tick()
      # already cleared eligible drains by this point.
      return if schedule.draining?

      host_port = miners_by_id[schedule.miner_id]
      return unless host_port # orphan: schedule for a miner no longer in miners.yml

      return unless in_window?(now, schedule.time_utc)
      return if already_fired_today?(schedule, now)

      fire_restart(schedule, host_port, now)
    end

    def in_window?(now, time_utc)
      now_minutes      = (now.hour * 60) + now.min
      hh, mm           = time_utc.split(':').map(&:to_i)
      schedule_minutes = (hh * 60) + mm
      delta = ((now_minutes - schedule_minutes) % 1440).then { |d| [d, 1440 - d].min }
      delta <= WINDOW_MINUTES
    end

    def already_fired_today?(schedule, now)
      schedule.last_scheduled_date_utc == now.strftime('%Y-%m-%d')
    end

    def fire_restart(schedule, host_port, now)
      host, port = host_port
      miner = @miner_factory.call(host, port)
      miner.restart
    rescue CgminerApiClient::Error, StandardError => e
      Logger.error(event: 'restart.scheduled.failed',
                   miner: schedule.miner_id, time_utc: schedule.time_utc,
                   error: e.class.to_s, message: e.message)
    else
      persist_fire(schedule, now)
      Logger.info(event: 'restart.scheduled.fired',
                  miner: schedule.miner_id, time_utc: schedule.time_utc)
    end

    def persist_fire(schedule, now)
      @store.update(schedule.miner_id) do |existing|
        # If the operator toggled the schedule between load and persist,
        # honor their newer values (enabled, time_utc) but record that
        # WE fired today using the schedule we acted on.
        base = existing || schedule
        base.with(last_restart_at: now.iso8601,
                  last_scheduled_date_utc: now.strftime('%Y-%m-%d'))
      end
    rescue StandardError => e
      Logger.error(event: 'restart.scheduled.persist_failed',
                   miner: schedule.miner_id,
                   error: e.class.to_s, message: e.message)
    end

    def configured_miners_index
      @configured_miners_provider.call.each_with_object({}) do |entry, acc|
        host, port, = entry
        acc["#{host}:#{port}"] = [host, port]
      end
    end

    def interruptible_sleep(seconds)
      @mutex.synchronize do
        @cv.wait(@mutex, seconds) unless @stopped
      end
    end
  end
end
