# frozen_string_literal: true

module CgminerManager
  FleetQueryEntry = Data.define(:miner, :ok, :response, :error) do
    def ok? = ok
  end

  FleetQueryResult = Data.define(:entries) do
    def ok_count     = entries.count(&:ok?)
    def failed_count = entries.count { |e| !e.ok? }
    def all_ok?      = entries.all?(&:ok?)

    # Count-by-code map of failed entries for `admin.result.failed_codes`.
    # Empty `{}` when nothing failed, so consumers can rely on the key
    # always being present. Six-symbol vocabulary documented in
    # cgminer_monitor's docs/log_schema.md `code` row.
    def failed_codes_count_map
      entries.reject(&:ok?).each_with_object(Hash.new(0)) do |entry, counts|
        counts[CgminerManager::AdminLogging.code_for(entry.error)] += 1
      end
    end
  end
end
