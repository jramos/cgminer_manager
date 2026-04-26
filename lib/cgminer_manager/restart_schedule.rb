# frozen_string_literal: true

module CgminerManager
  # One miner's daily-restart configuration. Persisted as JSON via
  # RestartStore; consumed by RestartScheduler. UTC-only by design — no
  # local-time semantics anywhere in the request, store, or scheduler.
  RestartSchedule = Data.define(
    :miner_id,
    :enabled,
    :time_utc,
    :last_restart_at,
    :last_scheduled_date_utc,
    # Drain-mode fields (v1.8.0+). All optional / nullable so existing
    # JSON files round-trip cleanly. `drained == true` and a non-nil
    # `drained_at` move together (validated below). `drained_by` is
    # the admin user that issued the drain (nil under AUTH=off or for
    # auto-resume-cleared entries). `auto_resume_attempt_count` and
    # `auto_resume_last_attempt_at` track scheduler-side backoff.
    :drained,
    :drained_at,
    :drained_by,
    :auto_resume_attempt_count,
    :auto_resume_last_attempt_at
  )

  class RestartSchedule # rubocop:disable Metrics/ClassLength
    TIME_UTC_PATTERN = /\A([01]\d|2[0-3]):[0-5]\d\z/
    DATE_UTC_PATTERN = /\A\d{4}-\d{2}-\d{2}\z/

    class InvalidError < StandardError; end

    def to_h
      {
        'miner_id' => miner_id,
        'enabled' => enabled,
        'time_utc' => time_utc,
        'last_restart_at' => last_restart_at,
        'last_scheduled_date_utc' => last_scheduled_date_utc,
        'drained' => drained,
        'drained_at' => drained_at,
        'drained_by' => drained_by,
        'auto_resume_attempt_count' => auto_resume_attempt_count,
        'auto_resume_last_attempt_at' => auto_resume_last_attempt_at
      }
    end

    def draining?
      drained == true
    end

    class << self
      # Convenience factory: takes the original 5 required fields plus
      # nullable drain fields with sensible defaults. Production +
      # spec callers that don't care about drain pass only the 5
      # required ones; the drain-aware route handler in HttpApp passes
      # all 10. Data.define itself doesn't support defaults so this
      # wrapper centralizes the convention.
      def build(miner_id:, enabled:, time_utc:, last_restart_at:, last_scheduled_date_utc:, # rubocop:disable Metrics/ParameterLists
                drained: false, drained_at: nil, drained_by: nil,
                auto_resume_attempt_count: 0, auto_resume_last_attempt_at: nil)
        new(miner_id: miner_id, enabled: enabled, time_utc: time_utc,
            last_restart_at: last_restart_at,
            last_scheduled_date_utc: last_scheduled_date_utc,
            drained: drained, drained_at: drained_at, drained_by: drained_by,
            auto_resume_attempt_count: auto_resume_attempt_count,
            auto_resume_last_attempt_at: auto_resume_last_attempt_at)
      end

      def parse(hash) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        raise InvalidError, "expected a Hash, got #{hash.class}" unless hash.is_a?(Hash)

        miner_id = hash['miner_id'] || hash[:miner_id]
        enabled  = hash.fetch('enabled') { hash[:enabled] }
        time_utc = hash['time_utc'] || hash[:time_utc]
        last_restart_at         = hash['last_restart_at'] || hash[:last_restart_at]
        last_scheduled_date_utc = hash['last_scheduled_date_utc'] || hash[:last_scheduled_date_utc]
        drained                 = hash.fetch('drained') { hash[:drained] }
        drained_at              = hash['drained_at'] || hash[:drained_at]
        drained_by              = hash['drained_by'] || hash[:drained_by]
        auto_resume_attempt_count   = hash.fetch('auto_resume_attempt_count') { hash[:auto_resume_attempt_count] }
        auto_resume_last_attempt_at = hash['auto_resume_last_attempt_at'] || hash[:auto_resume_last_attempt_at]

        # Default-on-absence (back-compat with pre-v1.8.0 JSON files).
        drained = false if drained.nil?
        auto_resume_attempt_count = 0 if auto_resume_attempt_count.nil?

        validate_miner_id!(miner_id)
        validate_enabled!(enabled)
        validate_time_utc!(time_utc, enabled: enabled)
        validate_optional_iso_string!(:last_restart_at, last_restart_at)
        validate_optional_date_utc!(last_scheduled_date_utc)
        validate_drained!(drained, drained_at)
        validate_optional_string!(:drained_by, drained_by)
        validate_auto_resume_attempt_count!(auto_resume_attempt_count)
        validate_optional_iso_string!(:auto_resume_last_attempt_at, auto_resume_last_attempt_at)

        new(miner_id: miner_id, enabled: enabled, time_utc: time_utc,
            last_restart_at: last_restart_at,
            last_scheduled_date_utc: last_scheduled_date_utc,
            drained: drained, drained_at: drained_at, drained_by: drained_by,
            auto_resume_attempt_count: auto_resume_attempt_count,
            auto_resume_last_attempt_at: auto_resume_last_attempt_at)
      end

      private

      def validate_miner_id!(value)
        return if value.is_a?(String) && !value.empty?

        raise InvalidError, "miner_id must be a non-empty string, got #{value.inspect}"
      end

      def validate_enabled!(value)
        return if value == true || value == false # rubocop:disable Style/MultipleComparison

        raise InvalidError, "enabled must be true or false, got #{value.inspect}"
      end

      def validate_time_utc!(value, enabled:)
        if enabled
          return if value.is_a?(String) && TIME_UTC_PATTERN.match?(value)

          raise InvalidError, "time_utc must be HH:MM (24h, UTC) when enabled, got #{value.inspect}"
        else
          return if value.nil?
          return if value.is_a?(String) && TIME_UTC_PATTERN.match?(value)

          raise InvalidError, "time_utc must be nil or HH:MM, got #{value.inspect}"
        end
      end

      def validate_optional_iso_string!(field, value)
        return if value.nil?
        return if value.is_a?(String) && !value.empty?

        raise InvalidError, "#{field} must be nil or a non-empty string, got #{value.inspect}"
      end

      def validate_optional_date_utc!(value)
        return if value.nil?
        return if value.is_a?(String) && DATE_UTC_PATTERN.match?(value)

        raise InvalidError, "last_scheduled_date_utc must be nil or YYYY-MM-DD, got #{value.inspect}"
      end

      def validate_optional_string!(field, value)
        return if value.nil?
        return if value.is_a?(String) && !value.empty?

        raise InvalidError, "#{field} must be nil or a non-empty string, got #{value.inspect}"
      end

      # Drain state must move atomically: drained == true requires a
      # drained_at, and drained == false forbids one. Anything else
      # implies operator intent didn't fully take effect (or some
      # serializer trimmed one of the two), and we'd rather fail-loud
      # than silently treat half-drain state as drained.
      def validate_drained!(drained, drained_at)
        unless [true, false].include?(drained)
          raise InvalidError, "drained must be true or false, got #{drained.inspect}"
        end

        if drained
          return if drained_at.is_a?(String) && !drained_at.empty?

          raise InvalidError, 'drained_at must be a non-empty ISO8601 string when ' \
                              "drained=true, got #{drained_at.inspect}"
        end

        return if drained_at.nil?

        raise InvalidError, "drained_at must be nil when drained=false, got #{drained_at.inspect}"
      end

      def validate_auto_resume_attempt_count!(value)
        return if value.is_a?(Integer) && value >= 0

        raise InvalidError, "auto_resume_attempt_count must be a non-negative Integer, got #{value.inspect}"
      end
    end
  end
end
