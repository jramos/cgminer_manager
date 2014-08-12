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
      if params[:args].present?
        @miner_pool.query(params[:command].to_sym, *params[:args].split(','))
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

  def retrieve_miner_data
    @miner_data ||= @miner_pool.query('version+coin+config')

    [:summary, :devs, :pools, :stats].each do |type|
      last_entry = "CgminerMonitor::Document::#{type.to_s.capitalize}".constantize.last_entry

      @miner_pool.miners.each_with_index do |miner, index|
        @miner_data[index][type] = [{type => last_entry[:results][index]}]
      end
    end
  end
end