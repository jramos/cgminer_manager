class Api::V1::PingController < ApplicationController
  def index
    render :json => {
      :timestamp => Time.now.to_i,
      :available_miners => @miner_pool.available_miners(true).count,
      :unavailable_miners => @miner_pool.unavailable_miners.count
    }
  end
end