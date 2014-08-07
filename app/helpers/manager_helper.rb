module ManagerHelper
  def get_chain_stats_for(miner_index, name)
    stats = @miner_data[miner_index][:stats].first[:stats]
    stats.detect{|stat| stat[:id] == name}
  end
end
