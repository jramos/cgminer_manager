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
    :last_scheduled_date_utc
  )

  class RestartSchedule
    TIME_UTC_PATTERN = /\A([01]\d|2[0-3]):[0-5]\d\z/
    DATE_UTC_PATTERN = /\A\d{4}-\d{2}-\d{2}\z/

    class InvalidError < StandardError; end

    def to_h
      {
        'miner_id' => miner_id,
        'enabled' => enabled,
        'time_utc' => time_utc,
        'last_restart_at' => last_restart_at,
        'last_scheduled_date_utc' => last_scheduled_date_utc
      }
    end

    class << self
      def parse(hash)
        raise InvalidError, "expected a Hash, got #{hash.class}" unless hash.is_a?(Hash)

        miner_id = hash['miner_id'] || hash[:miner_id]
        enabled  = hash.fetch('enabled') { hash[:enabled] }
        time_utc = hash['time_utc'] || hash[:time_utc]
        last_restart_at         = hash['last_restart_at'] || hash[:last_restart_at]
        last_scheduled_date_utc = hash['last_scheduled_date_utc'] || hash[:last_scheduled_date_utc]

        validate_miner_id!(miner_id)
        validate_enabled!(enabled)
        validate_time_utc!(time_utc, enabled: enabled)
        validate_optional_iso_string!(:last_restart_at, last_restart_at)
        validate_optional_date_utc!(last_scheduled_date_utc)

        new(miner_id: miner_id, enabled: enabled, time_utc: time_utc,
            last_restart_at: last_restart_at,
            last_scheduled_date_utc: last_scheduled_date_utc)
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
    end
  end
end
