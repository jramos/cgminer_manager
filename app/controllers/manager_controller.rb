require 'net/http'
require 'uri'

class ManagerController < ApplicationController
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
    @miner_pool.miners.each_with_index do |miner, index|
      uri = URI("http://127.0.0.1:3000/miner/#{index}/manage_pools")
      p = params.slice(*[:url, :user, :pass])
      Net::HTTP.post_form(uri, params.slice(*[:url, :user, :pass]))
    end

    @updated = 'Pools updated'
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