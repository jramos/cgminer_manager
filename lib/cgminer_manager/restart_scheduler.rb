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

    def initialize(store:, configured_miners_provider:,
                   clock: -> { Time.now.utc },
                   miner_factory: ->(host, port) { CgminerApiClient::Miner.new(host, port) })
      @store                      = store
      @configured_miners_provider = configured_miners_provider
      @clock                      = clock
      @miner_factory              = miner_factory
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
    def tick
      now           = @clock.call
      schedules     = @store.load
      miners_by_id  = configured_miners_index

      schedules.each_value do |schedule|
        process_schedule(schedule, now, miners_by_id)
      end
    end

    private

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
