class ManagerController < ApplicationController
  before_filter :setup_summary

  def index
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