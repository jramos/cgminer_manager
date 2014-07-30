module ManagerHelper
  def get_chain_stats_for(miner, name)
    miner.stats.detect{|stat| stat[:id] == name}
  end
end
