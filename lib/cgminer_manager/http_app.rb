# frozen_string_literal: true

require 'sinatra/base'
require 'sinatra/content_for'
require 'rack/protection'
require 'json'
require 'yaml'
require 'cgi'
require 'securerandom'
require 'time'
require 'cgminer_api_client'

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

    helpers Sinatra::ContentFor

    GRAPH_METRIC_PROJECTIONS = {
      'hashrate' => %w[ts ghs_5s ghs_av],
      'temperature' => %w[ts min avg max],
      'availability' => %w[ts available],
      'hardware_error' => %w[ts device_hardware_pct],
      'device_rejected' => %w[ts device_rejected_pct],
      'pool_rejected' => %w[ts pool_rejected_pct],
      'pool_stale' => %w[ts pool_stale_pct]
    }.freeze

    set :show_exceptions, false
    set :dump_errors, false
    set :host_authorization, { permitted_hosts: [] }
    set :views, File.expand_path('../../views', __dir__)

    configure do
      use Rack::Session::Cookie,
          key: 'cgminer_manager.session',
          secret: ENV.fetch('SESSION_SECRET') { SecureRandom.hex(32) },
          same_site: :lax
      use Rack::Protection::AuthenticityToken
    end

    helpers do
      def h(text) = Rack::Utils.escape_html(text.to_s)
      def raw(str) = str.to_s

      def root_url = '/'
      def miner_url(miner_id) = "/miner/#{CGI.escape(miner_id.to_s)}"
      def manager_manage_pools_path = '/manager/manage_pools'
      def miner_manage_pools_path(miner_id) = "#{miner_url(miner_id)}/manage_pools"

      def link_to(text, href, **opts)
        attrs = opts.map { |k, v| %(#{k}="#{h(v)}") }.join(' ')
        body  = text.is_a?(String) ? h(text) : text
        %(<a href="#{h(href)}" #{attrs}>#{body}</a>)
      end

      def image_tag(src, **opts)
        attrs = opts.map { |k, v| %(#{k}="#{h(v)}") }.join(' ')
        %(<img src="#{h(src)}" #{attrs}>)
      end

      def stylesheet_link_tag(name)
        %(<link rel="stylesheet" href="/css/#{h(name)}.css">)
      end

      def javascript_include_tag(name)
        %(<script src="/js/#{h(name)}.js"></script>)
      end

      def csrf_meta_tag
        %(<meta name="csrf-token" content="#{h(csrf_token)}">)
      end

      def csrf_meta_tags = csrf_meta_tag

      def csrf_token
        Rack::Protection::AuthenticityToken.token(env['rack.session'] || {})
      end

      def hidden_field_tag(name, value = nil)
        %(<input type="hidden" name="#{h(name)}" value="#{h(value)}">)
      end

      def text_field_tag(name, value = nil, placeholder: nil)
        ph = placeholder ? %( placeholder="#{h(placeholder)}") : ''
        %(<input type="text" name="#{h(name)}" value="#{h(value)}"#{ph}>)
      end

      def label_tag(name, text)
        %(<label for="#{h(name)}">#{h(text)}</label>)
      end

      def submit_tag(text)
        %(<input type="submit" value="#{h(text)}">)
      end

      def render_partial(name, locals: {})
        parts = name.split('/')
        parts[-1] = "_#{parts[-1]}"
        haml parts.join('/').to_sym, layout: false, locals: locals
      end

      def staleness_badge(fetched_at, threshold_seconds)
        return 'waiting for first poll' if fetched_at.nil? || fetched_at.to_s.empty?

        age_seconds = Time.now.utc - Time.parse(fetched_at.to_s)
        return nil if age_seconds < threshold_seconds

        minutes = (age_seconds / 60).to_i
        "updated #{minutes}m ago"
      end

      def build_dashboard_view_model
        begin
          miners = monitor_client.miners[:miners]
        rescue MonitorError => e
          fallback_miners = self.class.configured_miners.map do |host, port|
            { id: "#{host}:#{port}", host: host, port: port }
          end
          return { miners: fallback_miners, snapshots: {},
                   banner: "data source unavailable (#{e.message})",
                   stale_threshold: self.class.stale_threshold_seconds || 300 }
        end

        snapshots = fetch_snapshots_for(miners)
        { miners: miners, snapshots: snapshots, banner: nil,
          stale_threshold: self.class.stale_threshold_seconds || 300 }
      end

      def fetch_snapshots_for(miners)
        queue = Queue.new
        miners.each { |m| queue << m }
        results = {}
        mutex = Mutex.new

        worker_count = [self.class.pool_thread_cap || 8, miners.size].min
        worker_count = 1 if worker_count < 1
        threads = worker_count.times.map { spawn_snapshot_worker(queue, results, mutex) }
        threads.each(&:join)
        results
      end

      def spawn_snapshot_worker(queue, results, mutex)
        Thread.new do
          loop do
            miner = pop_or_break(queue) or break
            miner_id = miner[:id] || miner['id']
            tile = fetch_tile(miner_id)
            mutex.synchronize { results[miner_id] = tile }
          end
        end
      end

      def pop_or_break(queue)
        queue.pop(true)
      rescue ThreadError
        nil
      end

      def fetch_tile(miner_id)
        {
          summary: safe_fetch { monitor_client.summary(miner_id) },
          devices: safe_fetch { monitor_client.devices(miner_id) },
          pools: safe_fetch { monitor_client.pools(miner_id) },
          stats: safe_fetch { monitor_client.stats(miner_id) }
        }
      end

      def safe_fetch
        yield
      rescue MonitorError => e
        { error: e.message }
      end

      def miner_configured?(miner_id)
        self.class.configured_miners.any? { |host, port| "#{host}:#{port}" == miner_id }
      end

      def neighbor_urls(miner_id)
        ids = self.class.configured_miners.map { |host, port| "#{host}:#{port}" }
        idx = ids.index(miner_id)
        prev = idx&.positive? ? miner_url(ids[idx - 1]) : nil
        nxt  = idx && idx < ids.size - 1 ? miner_url(ids[idx + 1]) : nil
        [prev, nxt]
      end

      def build_miner_view_model(miner_id)
        {
          miner_id: miner_id,
          snapshots: {
            summary: safe_fetch { monitor_client.summary(miner_id) },
            devices: safe_fetch { monitor_client.devices(miner_id) },
            pools: safe_fetch { monitor_client.pools(miner_id) },
            stats: safe_fetch { monitor_client.stats(miner_id) }
          }
        }
      end
    end

    get '/' do
      @view = build_dashboard_view_model
      haml :'manager/index'
    end

    get '/miner/:miner_id' do
      miner_id = CGI.unescape(params[:miner_id])
      halt 404 unless miner_configured?(miner_id)

      @miner_id = miner_id
      @miner_url = miner_url(miner_id)
      @prev_miner_url, @next_miner_url = neighbor_urls(miner_id)
      @view = build_miner_view_model(miner_id)
      haml :'miner/show'
    end

    get '/miner/:miner_id/graph_data/:metric' do
      miner_id = CGI.unescape(params[:miner_id])
      halt 404 unless miner_configured?(miner_id)

      projection = GRAPH_METRIC_PROJECTIONS[params[:metric]]
      halt 404 unless projection

      envelope = monitor_client.graph_data(metric: params[:metric],
                                           miner_id: miner_id,
                                           since: params[:since])

      fields = envelope[:fields] || []
      rows   = envelope[:data]   || []
      indices = projection.map { |f| fields.index(f) }

      projected = rows.map { |row| indices.map { |i| i ? row[i] : nil } }

      content_type :json
      JSON.generate(projected)
    end

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

    get '/api/v1/ping.json' do
      content_type :json

      available = 0
      unavailable = 0
      self.class.configured_miners.each do |host, port|
        miner = CgminerApiClient::Miner.new(host, port)
        if miner.available?
          available += 1
        else
          unavailable += 1
        end
      end

      JSON.generate(
        timestamp: Time.now.to_i,
        available_miners: available,
        unavailable_miners: unavailable
      )
    end

    private

    def monitor_client
      @monitor_client ||= MonitorClient.new(base_url: self.class.monitor_url)
    end
  end
end
