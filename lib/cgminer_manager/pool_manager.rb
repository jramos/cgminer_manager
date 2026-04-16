# frozen_string_literal: true

module CgminerManager
  class PoolManager
    MinerEntry = Data.define(:miner, :command_status, :command_reason,
                             :save_status, :save_reason) do
      def ok?     = command_status == :ok && save_status == :ok
      def failed? = command_status == :failed
    end

    PoolActionResult = Data.define(:entries) do
      def all_ok?     = entries.all?(&:ok?)
      def any_failed? = entries.any?(&:failed?)
      def successful  = entries.select(&:ok?)
      def failed      = entries.select(&:failed?)
      def indeterminate = entries.select { |e| e.command_status == :indeterminate }
    end
  end
end
