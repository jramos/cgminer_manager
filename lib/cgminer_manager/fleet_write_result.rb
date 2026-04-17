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
  end
end
