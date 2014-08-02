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