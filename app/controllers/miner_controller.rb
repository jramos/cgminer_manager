class MinerController < ApplicationController
  include MinerHelper

  before_filter :lookup_miner

  def show
  end

  def run
    @results = begin
      @miner.query(params[:command].to_sym, params[:arguments].try(:split, ','))
    rescue
      'invalid command and/or parameters'
    end

    render partial: 'shared/run', layout: false
  end

  def manage_pools
    update_pools_for(@miner, params)

    @updated = 'Pools updated'
    render partial: 'shared/manage_pools', layout: false
  end

  private
  
  def lookup_miner
    @miner_id ||= params[:id].to_i
    @miner    ||= @miner_pool.miners[@miner_id]
  end
end
