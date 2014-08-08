class ManagerController < ApplicationController
  include MinerHelper

  before_filter :setup_summary, :only => [:index]
  before_filter :retrieve_miner_data, :only => [:index]

  def index
    if request.xhr?
      render layout: false && return
    end
  end

  def run
    @results = begin
      if params[:arguments].present?
        @miner_pool.query(params[:command].to_sym, *params[:arguments].split(','))
      else
        @miner_pool.query(params[:command].to_sym)
      end
    rescue StandardError => e
      "invalid command and/or parameters; #{e.message}"
    end

    render partial: 'shared/run', layout: false
  end

  def manage_pools
    threads = @miner_pool.miners.collect do |miner|
      Thread.new do
        update_pools_for(miner, params)
      end
    end
    threads.each { |thr| thr.join }

    @updated = threads.collect(&:value).flatten
    @miner = @miner_pool.miners.first
    render partial: 'shared/manage_pools', layout: false
  end

  private
  
  def setup_summary
    @summary = {
      :error_rate     => [],
      :ghs_avg        => [],
      :ghs_5s         => [],
      :net_bytes_sent => [],
      :net_bytes_recv => [],
      :pool_stale     => [],
      :rejected_rate  => [],
      :temperature    => [],
      :uptime         => []
    }
  end

  def retrieve_miner_data
    @miner_data ||= @miner_pool.query('version+summary+coin+devs+pools+stats+config')
  end
end