module MinerHelper
  def update_pools_for(miner, params)
    params        = params.slice(*[:url, :user, :pass])
    orig_pool_ids = miner.pools.collect{|pool| pool[:pool] }

    0.upto(2) do |i|
      j = i.to_s
      if params['url'][j].present? && params['user'][j].present? && params['pass'][j].present?
        miner.addpool(params['url'][j], params['user'][j], params['pass'][j])
      end
    end

    new_pool_ids = miner.pools.collect{|pool| pool[:pool] }
    added_pool_ids = new_pool_ids - orig_pool_ids

    if added_pool_ids.count > 0
      orig_pool_ids.each do |pool_id|
        begin
          miner.disablepool(pool_id)
        rescue Exception => e
          logger.info "Couldn't disable pool #{pool_id}: #{e.message}"
        end
      end

      sleep(1)

      orig_pool_ids.each do |pool_id|
        begin
          while(true)
            pool = miner.pools.detect{|pool| pool[:pool].to_s == pool_id.to_s}
            if pool && pool[:status] == 'Disabled'
              miner.removepool(pool_id)
              break
            end
          end
        rescue Exception => e
          logger.info "Couldn't remove pool #{pool_id}: #{e.message}"
        end
      end
    end
  end
end
