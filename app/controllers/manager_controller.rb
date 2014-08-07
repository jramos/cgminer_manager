require 'net/http'
require 'uri'

class ManagerController < ApplicationController
  include MinerHelper

  before_filter :setup_summary, :only => [:index]

  def index
  end

  def run
    @results = begin
      if params[:arguments].present?
        @miner_pool.query(params[:command].to_sym, *params[:arguments].split(','))
      else
        @miner_pool.query(params[:command].to_sym)
      end
    rescue
      'invalid command and/or parameters'
    end

    render partial: 'shared/run', layout: false
  end

  def manage_pools
    threads = @miner_pool.miners.enum_for(:each_with_index).collect do |miner, index|
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
      :ghs_avg     => [],
      :ghs_5s      => [],
      :error_rate  => [],
      :temperature => [],
      :uptime      => []
    }
  end
end