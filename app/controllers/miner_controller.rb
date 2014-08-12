class MinerController < ApplicationController
  include MinerHelper

  before_filter :setup_summary, :only => [:show]
  before_filter :lookup_miner

  def show
    if request.xhr?
      render layout: false && return
    end
  end

  def run
    @results = begin
      if params[:args].present?
        @miner.query(params[:command], *params[:args].split(','))
      else
        @miner.query(params[:command])
      end
    rescue StandardError => e
      "invalid command and/or parameters; #{e.message}"
    end

    @results = "command successful" if @results.nil?

    render partial: 'shared/run', layout: false
  end

  def manage_pools
    update_pools_for(@miner, params)

    @updated = 'Pools updated'
    render partial: 'shared/manage_pools', layout: false
  end

  private
  
  def lookup_miner
    @miner_id   ||= (params[:id] || params[:miner_id]).to_i
    @miner      ||= @miner_pool.miners[@miner_id]
    @miner_data ||= []

    if @miner
      @miner_data[@miner_id] = @miner.query('version+coin+usbstats+config')

      [:summary, :devs, :pools, :stats].each do |type|
        last_entry = "CgminerMonitor::Document::#{type.to_s.capitalize}".constantize.last_entry
        @miner_data[@miner_id][type] = [{type => last_entry[:results][@miner_id]}]
      end
    end
  end
end
