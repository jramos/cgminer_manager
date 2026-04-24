# frozen_string_literal: true

require 'json'
require 'fileutils'

module CgminerManager
  # JSON-backed store for RestartSchedule. Atomic-rename writes; one
  # mutex serializes load+update so concurrent UI POSTs and scheduler
  # ticks can't tear. The store is a singleton — Server builds it once
  # in configure_http_app and exposes it via HttpApp.settings.restart_store
  # so HTTP handlers and the RestartScheduler share state.
  #
  # File shape:
  #   {"schedules": [{"miner_id": "...", "enabled": true, ...}, ...]}
  # The wrapper Hash leaves room for future top-level fields (schema
  # version, etc.) without a migration.
  class RestartStore
    def initialize(path)
      @path  = path
      @mutex = Mutex.new
    end

    attr_reader :path

    def load
      @mutex.synchronize { read_from_disk }
    end

    # Loads, yields the existing schedule (or nil) for miner_id, persists
    # the block's return value (a RestartSchedule). Returns the new
    # schedule. The whole load/modify/save is mutex-serialized so
    # concurrent updates can't lose-update each other.
    def update(miner_id)
      @mutex.synchronize do
        schedules = read_from_disk
        new_schedule = yield(schedules[miner_id])
        unless new_schedule.is_a?(RestartSchedule)
          raise ArgumentError, "block must return RestartSchedule, got #{new_schedule.class}"
        end

        schedules[miner_id] = new_schedule
        write_to_disk(schedules)
        new_schedule
      end
    end

    # Bulk replace. Used by the scheduler when it persists timestamp
    # updates after a successful restart fire — it loads, mutates many
    # entries, then replaces the whole map atomically.
    def replace(schedules)
      @mutex.synchronize { write_to_disk(schedules) }
    end

    private

    def read_from_disk
      return {} unless File.exist?(@path)

      raw = File.read(@path)
      parsed = JSON.parse(raw)
      list = parsed.is_a?(Hash) ? parsed['schedules'] : nil
      return {} unless list.is_a?(Array)

      list.each_with_object({}) do |entry, acc|
        schedule = RestartSchedule.parse(entry)
        acc[schedule.miner_id] = schedule
      rescue RestartSchedule::InvalidError => e
        Logger.warn(event: 'restart.store.entry_skipped',
                    error: e.class.to_s, message: e.message)
      end
    rescue JSON::ParserError, IOError, SystemCallError => e
      Logger.warn(event: 'restart.store.load_failed',
                  path: @path, error: e.class.to_s, message: e.message)
      {}
    end

    def write_to_disk(schedules)
      payload = JSON.pretty_generate(schedules: schedules.values.map(&:to_h))
      FileUtils.mkdir_p(File.dirname(@path))
      tmp = "#{@path}.tmp"
      File.write(tmp, payload)
      File.rename(tmp, @path)
    end
  end
end
