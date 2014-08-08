module ManagerHelper
  def get_stats_for(miner_index, stat_name)
    stats = @miner_data[miner_index][:stats].first[:stats]
    stats.detect{|stat| stat[:id] == stat_name}
  end
end
