# frozen_string_literal: true

module CgminerManager
  FleetQueryEntry = Data.define(:miner, :ok, :response, :error) do
    def ok? = ok
  end

  FleetQueryResult = Data.define(:entries) do
    def ok_count     = entries.count(&:ok?)
    def failed_count = entries.count { |e| !e.ok? }
    def all_ok?      = entries.all?(&:ok?)
  end
end
