class MinerController < ApplicationController
  before_filter :lookup_miner

  def show
  end

  private
  
  def lookup_miner
    @miner ||= @miner_pool.miners[params[:id].to_i]
  end
end
