# frozen_string_literal: true

module CgminerManager
  # A single miner's response to a non-pool write command (zero/save/restart/
  # quit or raw RPC). Unlike PoolManager's MinerEntry there is no save_status
  # field — save-after-command is a pool-management idiom, not a general one.
  FleetWriteEntry = Data.define(:miner, :status, :response, :error) do
    def ok?     = status == :ok
    def failed? = status == :failed
  end

  FleetWriteResult = Data.define(:entries) do
    def ok_count     = entries.count(&:ok?)
    def failed_count = entries.count(&:failed?)
    def all_ok?      = entries.all?(&:ok?)
    def any_failed?  = entries.any?(&:failed?)

    # Count-by-code map of failed entries for `admin.result.failed_codes`.
    # Empty `{}` when nothing failed, so consumers can rely on the key
    # always being present. Six-symbol vocabulary documented in
    # cgminer_monitor's docs/log_schema.md `code` row.
    def failed_codes_count_map
      entries.select(&:failed?).each_with_object(Hash.new(0)) do |entry, counts|
        counts[CgminerManager::ErrorCode.classify(entry.error)] += 1
      end
    end
  end
end
