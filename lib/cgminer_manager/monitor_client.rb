# frozen_string_literal: true

require 'http'
require 'json'
require 'cgi'

module CgminerManager
  class MonitorClient
    def initialize(base_url:, timeout_ms: 2000, request_id: nil)
      @base_url   = base_url.sub(%r{/\z}, '')
      @timeout_s  = timeout_ms / 1000.0
      @request_id = request_id
    end

    def miners
      get('/v2/miners')
    end

    def summary(miner_id)  = get("/v2/miners/#{CGI.escape(miner_id)}/summary")
    def devices(miner_id)  = get("/v2/miners/#{CGI.escape(miner_id)}/devices")
    def pools(miner_id)    = get("/v2/miners/#{CGI.escape(miner_id)}/pools")
    def stats(miner_id)    = get("/v2/miners/#{CGI.escape(miner_id)}/stats")

    def graph_data(metric:, miner_id: nil, since: nil)
      params = {}
      params[:miner] = miner_id if miner_id
      params[:since] = since    if since
      get("/v2/graph_data/#{metric}", params: params)
    end

    def healthz
      get('/v2/healthz')
    end

    private

    def get(path, params: {})
      started = Time.now
      client  = HTTP.timeout(@timeout_s)
      client  = client.headers('X-Cgminer-Request-Id' => @request_id) if @request_id
      response = client.get("#{@base_url}#{path}", params: params)
      log_call(path, response, started)
      raise_api_error(response) unless response.status.success?

      JSON.parse(response.body.to_s, symbolize_names: true)
    rescue HTTP::ConnectionError, HTTP::TimeoutError, Errno::ECONNREFUSED => e
      Logger.warn(event: 'monitor.call.failed',
                  request_id: @request_id,
                  url: path,
                  error: e.class.to_s,
                  message: e.message)
      raise MonitorError::ConnectionError, "monitor unreachable: #{e.message}"
    end

    def log_call(path, response, started)
      duration_ms = ((Time.now - started) * 1000).round
      Logger.info(event: 'monitor.call',
                  request_id: @request_id,
                  url: path,
                  status: response.status.to_i,
                  duration_ms: duration_ms)
    end

    def raise_api_error(response)
      raise MonitorError::ApiError.new("monitor returned #{response.status}",
                                       status: response.status.to_i,
                                       body: response.body.to_s)
    end
  end
end
