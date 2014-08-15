class ApplicationController < ActionController::Base
  before_filter :load_miner_pool

  private

  def load_miner_pool
    @miner_pool ||= MINER_POOL
  end
end