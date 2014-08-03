class MinerController < ApplicationController
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
    pools = @miner.pools.clone

    0.upto(pools.count - 1) do |i|
      @miner.disablepool(i)
    end

    0.upto(2) do |i|
      j = i.to_s
      if params['url'][j].present? && params['user'][j].present? && params['pass'][j].present?
        @miner.addpool(params['url'][j], params['user'][j], params['pass'][j])
      end
    end

    sleep(5)  # wait for old pools to be disabled

    0.upto(pools.count - 1) do |i|
      @miner.removepool(i)
    end

    @updated = 'Pools updated'
    render partial: 'shared/manage_pools', layout: false
  end

  private
  
  def lookup_miner
    @miner_id ||= params[:id].to_i
    @miner    ||= @miner_pool.miners[@miner_id]
  end
end
