class ApplicationController < ActionController::Base
  # Prevent CSRF attacks by raising an exception.
  # For APIs, you may want to use :null_session instead.
  protect_from_forgery with: :exception

  before_filter :load_miner_pool

  private

  def load_miner_pool
    @miner_pool ||= CgminerApiClient::MinerPool.new
  end
end