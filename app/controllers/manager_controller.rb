class ManagerController < ApplicationController
  before_filter :load_miner_pool
  before_filter :setup_summary

  def index
  end

  private
  
  def load_miner_pool
    @miner_pool = CgminerApiClient::MinerPool.new
  end
  
  def setup_summary
    @summary = {
      :ghs_avg     => [],
      :ghs_5s      => [],
      :error_rate  => [],
      :temperature => []
    }
  end
end