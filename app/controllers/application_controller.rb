class ApplicationController < ActionController::Base
  before_filter :load_miner_pool

  private

  def setup_summary
    @summary = {
      :error_rate     => [],
      :ghs_avg        => [],
      :ghs_5s         => [],
      :net_bytes_sent => [],
      :net_bytes_recv => [],
      :pool_stale     => [],
      :rejected_rate  => [],
      :temperature    => [],
      :uptime         => []
    }
  end

  def load_miner_pool
    @miner_pool ||= MINER_POOL
  end
end