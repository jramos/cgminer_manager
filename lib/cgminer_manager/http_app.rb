# frozen_string_literal: true

require 'sinatra/base'
require 'rack/protection'
require 'json'
require 'yaml'

module CgminerManager
  class HttpApp < Sinatra::Base
    class << self
      attr_accessor :monitor_url, :miners_file, :stale_threshold_seconds, :pool_thread_cap

      def configure_for_test!(monitor_url:, miners_file:,
                              stale_threshold_seconds: 300,
                              pool_thread_cap: 8)
        self.monitor_url             = monitor_url
        self.miners_file             = miners_file
        self.stale_threshold_seconds = stale_threshold_seconds
        self.pool_thread_cap         = pool_thread_cap
        reset_configured_miners! if respond_to?(:reset_configured_miners!)
      end

      def configured_miners
        @configured_miners ||= parse_miners_file
      end

      def reset_configured_miners!
        @configured_miners = nil
      end

      private

      def parse_miners_file
        raw = YAML.safe_load_file(miners_file) || []
        validate_miners_shape!(raw)
        raw.map { |m| [m['host'], m['port'] || 4028].freeze }.freeze
      end

      def validate_miners_shape!(raw)
        return if raw.is_a?(Array) && raw.all? { |m| m.is_a?(Hash) && m['host'] }

        raise ConfigError, "#{miners_file} must be a YAML list of {host, port} entries"
      end
    end

    set :show_exceptions, false
    set :dump_errors, false
    set :host_authorization, { permitted_hosts: [] }

    get '/healthz' do
      reasons = []

      begin
        self.class.configured_miners
      rescue StandardError => e
        reasons << "miners.yml unparseable: #{e.message}"
      end

      begin
        monitor_client.healthz
      rescue MonitorError => e
        reasons << "monitor unhealthy: #{e.message}"
      end

      content_type :json
      if reasons.empty?
        status 200
        JSON.generate(ok: true)
      else
        status 503
        JSON.generate(ok: false, reasons: reasons)
      end
    end

    private

    def monitor_client
      @monitor_client ||= MonitorClient.new(base_url: self.class.monitor_url)
    end
  end
end
