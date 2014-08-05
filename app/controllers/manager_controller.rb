require 'net/http'
require 'uri'

class ManagerController < ApplicationController
  include MinerHelper

  before_filter :setup_summary

  def index
  end

  def run
    @results = begin
      @miner_pool.query(params[:command].to_sym, params[:arguments].try(:split, ','))
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