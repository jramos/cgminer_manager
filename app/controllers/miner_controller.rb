class MinerController < ApplicationController
  include MinerHelper

  before_filter :lookup_miner

  def show
    if request.xhr?
      render layout: false && return
    end
  end

  def run
    @results = begin
      if params[:arguments].present?
        @miner.query(params[:command].to_sym, *params[:arguments].split(','))
      else
        @miner.query(params[:command].to_sym)
      end
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
