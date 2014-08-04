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
    orig_pool_ids = @miner.pools.collect{|pool| pool[:pool] }

    0.upto(2) do |i|
      j = i.to_s
      if params['url'][j].present? && params['user'][j].present? && params['pass'][j].present?
        @miner.addpool(params['url'][j], params['user'][j], params['pass'][j])
      end
    end

    new_pool_ids = @miner.pools.collect{|pool| pool[:pool] }
    added_pool_ids = new_pool_ids - orig_pool_ids

    if added_pool_ids.count > 0
      @miner.enablepool(added_pool_ids.first)

      orig_pool_ids.each do |pool_id|
        begin
          @miner.disablepool(pool_id)

          while(true)
            pool = @miner.pools.detect{|pool| pool[:pool].to_s == pool_id.to_s}
            if pool[:status] == 'Disabled'
              @miner.removepool(pool_id)
              break
            end
          end
        rescue Exception => e
          logger.info "Couldn't disable/remove pool #{pool_id}: #{e.message}"
        end
      end
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
