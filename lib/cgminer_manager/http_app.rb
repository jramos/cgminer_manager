# frozen_string_literal: true

require 'sinatra/base'
require 'sinatra/content_for'
require 'rack/protection'
require 'digest'
require 'json'
require 'yaml'
require 'cgi'
require 'securerandom'
require 'time'
require 'cgminer_api_client'

# Render CgminerApiClient::Miner as "host:port" so PoolManager's
# MinerEntry#miner (populated via miner.to_s) displays as a stable
# identifier rather than the default Object#to_s inspection string.
# Upstream does not define to_s, and #respond_to_missing? excludes
# names starting with 'to_', so this is a safe host-side addition.
CgminerApiClient::Miner.class_eval do
  def to_s = "#{host}:#{port}"
end

module CgminerManager
  class HttpApp < Sinatra::Base
    # Sinatra auto-detects root from the file that defined this class (here
    # lib/cgminer_manager/http_app.rb), which would resolve public_folder to
    # lib/cgminer_manager/public. Pin root to the repo root so /public and
    # /views load from their actual locations.
    set :root, File.expand_path('../..', __dir__)

    # App state written by Server#configure_http_app before Puma accepts
    # its first request. Defaults intentionally `nil` / false for things
    # whose absence would silently lie to a caller; the `configured_miners`
    # instance helper raises if read before the setting is populated.
    set :monitor_url,             nil
    set :miners_file,             nil
    set :configured_miners,       nil
    set :stale_threshold_seconds, 300
    set :pool_thread_cap,         8
    set :monitor_timeout_ms,      2000
    set :session_secret,          nil
    set :production,              false

    # Parses miners.yml into the frozen `[host, port, label]` tuple list
    # consumed by routes. Server#configure_http_app and
    # `configure_for_test!` both use it to eagerly populate
    # `settings.configured_miners`; nothing lazy-loads on first request.
    def self.parse_miners_file(path)
      raw = YAML.safe_load_file(path) || []
      validate_miners_shape!(path, raw)
      raw.map { |m| [m['host'], m['port'] || 4028, m['label']].freeze }.freeze
    end

    def self.validate_miners_shape!(path, raw)
      return if raw.is_a?(Array) && raw.all? { |m| m.is_a?(Hash) && m['host'] }

      raise ConfigError, "#{path} must be a YAML list of {host, port} entries"
    end

    # Spec harness. Preserves the existing public signature so no spec
    # file needs to change. Eagerly parses miners_file into the setting
    # so specs don't rely on a later lazy load.
    def self.configure_for_test!(monitor_url:, miners_file:, # rubocop:disable Metrics/ParameterLists
                                 stale_threshold_seconds: 300,
                                 pool_thread_cap: 8,
                                 monitor_timeout_ms: 2000,
                                 session_secret: 'x' * 64,
                                 production: false)
      set :monitor_url,             monitor_url
      set :miners_file,             miners_file
      set :configured_miners,       parse_miners_file(miners_file)
      set :stale_threshold_seconds, stale_threshold_seconds
      set :pool_thread_cap,         pool_thread_cap
      set :monitor_timeout_ms,      monitor_timeout_ms
      set :session_secret,          session_secret
      set :production,              production
    end

    helpers Sinatra::ContentFor

    GRAPH_METRIC_PROJECTIONS = {
      'hashrate' => %w[ts ghs_5s ghs_av device_hardware_pct device_rejected_pct pool_rejected_pct pool_stale_pct],
      'temperature' => %w[ts min avg max],
      'availability' => %w[ts available configured]
    }.freeze

    # Typed admin verbs — stable URLs, typed confirm copy in the UI.
    # Not a security boundary: anyone with access to /admin/run can
    # execute any cgminer verb. Defense lives in Basic Auth + scope
    # restrictions + audit logging.
    ALLOWED_ADMIN_QUERIES = %w[version stats devs].freeze
    ALLOWED_ADMIN_WRITES  = %w[zero save restart quit].freeze

    # Device-tuning verbs that must target a single miner: broadcasting
    # clock/voltage tuning to heterogeneous hardware can damage ASICs.
    SCOPE_RESTRICTED_VERBS = %w[
      pgaset ascset pgarestart ascrestart
      pgaenable pgadisable ascenable ascdisable
    ].freeze

    # Raw RPC command param shape — no whitespace, no path traversal, no
    # null bytes. Still permits every cgminer verb.
    ADMIN_RAW_COMMAND_PATTERN = /\A[a-z][a-z0-9_+]*\z/

    set :show_exceptions, false
    set :dump_errors, false
    set :host_authorization, { permitted_hosts: [] }
    set :views, File.expand_path('../../views', __dir__)

    before do
      @request_started_at = Time.now
      @request_id         = SecureRandom.uuid if admin_path?(request.path_info)
    end

    after do
      Logger.info(event: 'http.request',
                  path: request.path,
                  method: request.request_method,
                  status: response.status,
                  render_ms: ((Time.now - @request_started_at) * 1000).round)
    end

    configure do
      use Rack::Session::Cookie,
          key: 'cgminer_manager.session',
          # NOTE: `session_secret` resolves at class-body eval time, which
          # is before Server#configure_http_app has populated the setting.
          # See https://github.com/jramos/cgminer_manager/issues/10 —
          # tracked for a follow-up PR that moves this `use` call into
          # Server#configure_http_app so the operator's configured secret
          # actually reaches the middleware.
          secret: session_secret || SecureRandom.hex(32),
          same_site: :lax,
          # Gate on production so dev/test over plain HTTP on 127.0.0.1
          # keeps working. Operators running in production are expected
          # to terminate TLS at a reverse proxy per the README security
          # posture; this prevents the session cookie from being sent
          # back over a non-HTTPS hop.
          secure: production?
      use CgminerManager::AdminAuth
      use CgminerManager::ConditionalAuthenticityToken
    end

    helpers do
      def h(text) = Rack::Utils.escape_html(text.to_s)

      # `raw` is a marker for "trust this string; do not HTML-escape it".
      # Haml 6's default escape (triggered by `=`) only skips strings that
      # report `html_safe? == true`; stamp the return accordingly so callers
      # can write `= raw('...')` without seeing entities in output.
      def raw(str)
        s = str.to_s.dup
        s.define_singleton_method(:html_safe?) { true }
        s
      end

      def root_url = '/'
      def miner_url(miner_id) = "/miner/#{CGI.escape(miner_id.to_s)}"
      def manager_manage_pools_path = '/manager/manage_pools'
      def miner_manage_pools_path(miner_id) = "#{miner_url(miner_id)}/manage_pools"
      def manager_admin_path(command) = "/manager/admin/#{command}"
      def miner_admin_path(miner_id, command) = "#{miner_url(miner_id)}/admin/#{command}"
      def admin_path?(path) = path.match?(%r{\A/(?:manager|miner/[^/]+)/admin(?:/|\z)})

      # Translates a raw "host:port" miner identifier into its display
      # label when miners.yml specifies one, otherwise returns the
      # identifier verbatim. Used by the admin result partials so rows
      # show "192.168.1.151:4028" (the label) instead of
      # "127.0.0.1:40281" (the routed host).
      def miner_display(host_port)
        configured_labels_by_id[host_port] || host_port
      end

      def link_to(text, href, **opts)
        attrs = opts.map { |k, v| %(#{k}="#{h(v)}") }.join(' ')
        body  = text.respond_to?(:html_safe?) && text.html_safe? ? text : h(text.to_s)
        raw(%(<a href="#{h(href)}" #{attrs}>#{body}</a>))
      end

      def image_tag(src, **opts)
        attrs = opts.map { |k, v| %(#{k}="#{h(v)}") }.join(' ')
        raw(%(<img src="#{h(src)}" #{attrs}>))
      end

      def stylesheet_link_tag(name)
        raw(%(<link rel="stylesheet" href="/css/#{h(name)}.css?v=#{VERSION}">))
      end

      def javascript_include_tag(name)
        raw(%(<script src="/js/#{h(name)}.js?v=#{VERSION}"></script>))
      end

      # Version-stamped static asset URL. Append ?v=VERSION so each
      # release busts the browser cache for CSS/JS without relying on
      # HTTP cache headers (which Sinatra's static-file server doesn't
      # set by default).
      def asset_url(path) = "#{path}?v=#{VERSION}"

      def csrf_meta_tag
        raw(%(<meta name="csrf-token" content="#{h(csrf_token)}">))
      end

      def csrf_meta_tags = csrf_meta_tag

      def csrf_token
        Rack::Protection::AuthenticityToken.token(env['rack.session'] || {})
      end

      def hidden_field_tag(name, value = nil)
        raw(%(<input type="hidden" name="#{h(name)}" value="#{h(value)}">))
      end

      def text_field_tag(name, value = nil, placeholder: nil)
        ph = placeholder ? %( placeholder="#{h(placeholder)}") : ''
        raw(%(<input type="text" name="#{h(name)}" value="#{h(value)}"#{ph}>))
      end

      def label_tag(name, text)
        raw(%(<label for="#{h(name)}">#{h(text)}</label>))
      end

      def submit_tag(text)
        raw(%(<input type="submit" value="#{h(text)}">))
      end

      def render_partial(name, locals: {})
        parts = name.split('/')
        parts[-1] = "_#{parts[-1]}"
        html_safe(haml(parts.join('/').to_sym, layout: false, locals: locals))
      end

      # Haml 6's default escape_html treats any String emitted via `=` as
      # unsafe unless the object reports `html_safe? == true`. Embedded
      # partials (whether from `render_partial` or bare `haml :name`) are
      # already rendered HTML. Stamping the return value avoids the visible
      # double-escape cascade seen in layout.haml's `= haml :_header`.
      def html_safe(str)
        str.define_singleton_method(:html_safe?) { true } unless str.respond_to?(:html_safe?)
        str
      end

      def staleness_badge(fetched_at, threshold_seconds)
        return 'waiting for first poll' if fetched_at.nil? || fetched_at.to_s.empty?

        age_seconds = Time.now.utc - Time.parse(fetched_at.to_s)
        return nil if age_seconds < threshold_seconds

        minutes = (age_seconds / 60).to_i
        "updated #{minutes}m ago"
      end

      def format_hashrate(rate)
        rate = rate.to_f
        unit = 'H/s'
        %w[KH/s MH/s GH/s TH/s PH/s EH/s ZH/s YH/s].each do |next_unit|
          break if rate < 1000

          rate /= 1000
          unit = next_unit
        end
        "#{rate.round(2)} #{unit}"
      end

      def number_with_delimiter(num)
        return '' if num.nil?

        whole, dec = num.to_s.split('.', 2)
        whole = whole.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
        dec ? "#{whole}.#{dec}" : whole
      end

      # NOTE: the legacy view call sites use this (mis)spelling verbatim.
      def to_ferinheight(centigrade)
        ((1.8 * centigrade.to_f) + 32).round(1)
      end

      def time_ago_in_words(input)
        seconds = case input
                  when Numeric then input
                  when Time    then Time.now - input
                  when String  then Time.now - Time.parse(input)
                  else 0
                  end.to_i.abs

        return "#{seconds}s" if seconds < 60
        return "#{seconds / 60}m" if seconds < 3600
        return "#{seconds / 3600}h" if seconds < 86_400

        "#{seconds / 86_400}d"
      end

      def get_stats_for(miner_index, stat_name)
        slice = @miner_data&.dig(miner_index, :stats)
        stats = slice&.first&.dig(:stats) || []
        stats.detect { |entry| entry[:id].to_s == stat_name.to_s }
      end

      # Build a ViewMinerPool from monitor's /v2/miners response. Accepts
      # either the live Hash list (with :available flag) or the fallback
      # array built when monitor is down (all :available=false).
      def build_view_miner_pool(monitor_miners)
        labels_by_id = configured_labels_by_id
        view_miners = (monitor_miners || []).map do |m|
          build_view_miner_from_monitor(m, labels_by_id)
        end
        ViewMinerPool.new(miners: view_miners)
      end

      # Fail-loud accessor — an unconfigured App raises a clear error
      # rather than silently returning an empty miners list or NoMethodError
      # when routes try to iterate it.
      def configured_miners
        settings.configured_miners || raise(
          'HttpApp not configured; call Server#configure_http_app or configure_for_test!'
        )
      end

      def configured_labels_by_id
        configured_miners.each_with_object({}) do |(host, port, label), acc|
          acc["#{host}:#{port}"] = label
        end
      end

      def build_view_miner_from_monitor(raw, labels_by_id)
        host  = raw[:host] || raw['host']
        port  = raw[:port] || raw['port']
        avail = raw.fetch(:available) { raw['available'] || false }
        ViewMiner.build(host, port, avail, labels_by_id["#{host}:#{port}"])
      end

      # Variant for the per-miner page, where we only need to thread the
      # configured miner list into @miner_pool for any partial that reaches
      # for it. Monitor availability isn't fetched separately here.
      def build_view_miner_pool_from_yml
        view_miners = configured_miners.map do |host, port, label|
          ViewMiner.build(host, port, false, label)
        end
        ViewMinerPool.new(miners: view_miners)
      end

      def build_dashboard_view_model
        begin
          miners = monitor_client.miners[:miners]
        rescue MonitorError => e
          fallback_miners = configured_miners.map do |host, port|
            { id: "#{host}:#{port}", host: host, port: port }
          end
          return { miners: fallback_miners, snapshots: {},
                   banner: "data source unavailable (#{e.message})",
                   stale_threshold: settings.stale_threshold_seconds || 300 }
        end

        snapshots = fetch_snapshots_for(miners)
        { miners: miners, snapshots: snapshots, banner: nil,
          stale_threshold: settings.stale_threshold_seconds || 300 }
      end

      def fetch_snapshots_for(miners)
        queue = Queue.new
        miners.each { |m| queue << m }
        results = {}
        mutex = Mutex.new

        worker_count = [settings.pool_thread_cap || 8, miners.size].min
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
        configured_miners.any? { |host, port| "#{host}:#{port}" == miner_id }
      end

      def neighbor_urls(miner_id)
        ids = configured_miners.map { |host, port| "#{host}:#{port}" }
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

      def build_pool_manager_for_all
        miners = configured_miners.map do |host, port|
          CgminerApiClient::Miner.new(host, port)
        end
        PoolManager.new(miners, thread_cap: settings.pool_thread_cap || 8)
      end

      def build_pool_manager_for(miner_ids)
        miners = miner_ids.map do |id|
          host, port = id.split(':', 2)
          CgminerApiClient::Miner.new(host, port.to_i)
        end
        PoolManager.new(miners)
      end

      def build_commander_for_all
        miners = configured_miners.map do |host, port|
          CgminerApiClient::Miner.new(host, port)
        end
        CgminerCommander.new(miners: miners, thread_cap: settings.pool_thread_cap || 8)
      end

      def build_commander_for(miner_ids)
        miners = miner_ids.map do |id|
          host, port = id.split(':', 2)
          CgminerApiClient::Miner.new(host, port.to_i)
        end
        CgminerCommander.new(miners: miners, thread_cap: settings.pool_thread_cap || 8)
      end

      def admin_session_id_hash
        sid = request.env['rack.session']&.id || ''
        Digest::SHA256.hexdigest(sid.to_s)[0..11]
      end

      def log_admin_command(event, **extra)
        Logger.info(event: event,
                    request_id: @request_id,
                    user: request.env['cgminer_manager.admin_user'],
                    remote_ip: request.ip,
                    user_agent: request.user_agent,
                    session_id_hash: admin_session_id_hash,
                    **extra)
      end

      def log_admin_result(command, scope, result, started_at)
        Logger.info(
          event: 'admin.result',
          request_id: @request_id,
          command: command,
          scope: scope,
          ok_count: result.ok_count,
          failed_count: result.failed_count,
          elapsed_ms: ((Time.now - started_at) * 1000).round
        )
      end

      def render_admin_result(result)
        if result.is_a?(FleetQueryResult)
          @query_result = result
          render_partial('shared/fleet_query')
        else
          @write_result = result
          render_partial('shared/fleet_write')
        end
      end

      def dispatch_pool_action(pool_manager, action_name, pool_index)
        case action_name.to_s
        when 'disable' then pool_manager.disable_pool(pool_index: pool_index)
        when 'enable'  then pool_manager.enable_pool(pool_index: pool_index)
        when 'remove'  then pool_manager.remove_pool(pool_index: pool_index)
        when 'add'     then pool_manager.add_pool(url: params[:url], user: params[:user], pass: params[:pass])
        else halt 400, "unknown action: #{action_name}"
        end
      end
    end

    not_found do
      content_type :html
      haml :'errors/404', layout: false
    end

    error do
      err = env['sinatra.error']
      Logger.error(event: 'http.500', error: err.class.to_s,
                   message: err.message,
                   backtrace: err.backtrace&.first(10))
      content_type :html
      haml :'errors/500', layout: false
    end

    get '/' do
      @view               = build_dashboard_view_model
      @miner_pool         = build_view_miner_pool(@view[:miners])
      @miner_data         = SnapshotAdapter.build_miner_data(configured_miners,
                                                             @view[:snapshots])
      @bad_chain_elements = []
      haml :'manager/index'
    end

    get '/miner/:miner_id' do
      miner_host_port = CGI.unescape(params[:miner_id])
      halt 404 unless miner_configured?(miner_host_port)

      miner_index = configured_miners
                    .map { |h, p| "#{h}:#{p}" }.index(miner_host_port)
      host, port, label = configured_miners[miner_index]

      @view        = build_miner_view_model(miner_host_port)
      snap_summary = @view[:snapshots][:summary]
      snap_ok      = snap_summary.is_a?(Hash) && !snap_summary[:error] && snap_summary[:response]

      @miner_id           = miner_index
      @miner_host_port    = miner_host_port
      @miner_url          = miner_url(miner_host_port)
      @prev_miner_url, @next_miner_url = neighbor_urls(miner_host_port)
      @miner              = ViewMiner.build(host, port, snap_ok ? true : false, label)
      @miner_pool         = build_view_miner_pool_from_yml
      @miner_data         = SnapshotAdapter.build_miner_data(
        configured_miners, miner_host_port => @view[:snapshots]
      )
      @bad_chain_elements = []
      haml :'miner/show'
    end

    post '/manager/manage_pools' do
      action_name = params[:action_name].to_s
      pool_index  = params[:pool_index].to_i

      pm = build_pool_manager_for_all
      @result = dispatch_pool_action(pm, action_name, pool_index)
      render_partial('shared/manage_pools')
    end

    post '/miner/:miner_id/manage_pools' do
      miner_id = CGI.unescape(params[:miner_id])
      halt 404 unless miner_configured?(miner_id)

      pm = build_pool_manager_for([miner_id])
      @result = dispatch_pool_action(pm, params[:action_name], params[:pool_index].to_i)
      render_partial('shared/manage_pools')
    end

    post '/manager/admin/run' do
      command = params[:command].to_s
      halt 422, "invalid command: #{command}" unless ADMIN_RAW_COMMAND_PATTERN.match?(command)

      scope = params[:scope].to_s
      if scope == 'all' && SCOPE_RESTRICTED_VERBS.include?(command)
        log_admin_command('admin.scope_rejected', command: command, scope: scope)
        halt 422, "command '#{command}' cannot target scope=all"
      end

      halt 422, "unknown scope: #{scope}" if scope != 'all' && !miner_configured?(scope)

      commander = scope == 'all' ? build_commander_for_all : build_commander_for([scope])

      log_admin_command('admin.raw_command', command: command, args: params[:args].to_s, scope: scope)
      started = Time.now
      result  = commander.raw!(command: command, args: params[:args])
      log_admin_result("raw:#{command}", scope, result, started)
      render_admin_result(result)
    end

    post '/manager/admin/:command' do
      command = params[:command].to_s
      halt 404 unless ALLOWED_ADMIN_QUERIES.include?(command) || ALLOWED_ADMIN_WRITES.include?(command)

      log_admin_command('admin.command', command: command, scope: 'all')
      started   = Time.now
      commander = build_commander_for_all
      result =
        if ALLOWED_ADMIN_QUERIES.include?(command)
          commander.public_send(command)
        else
          commander.public_send("#{command}!")
        end
      log_admin_result(command, 'all', result, started)
      render_admin_result(result)
    end

    post '/miner/:miner_id/admin/run' do
      miner_id = CGI.unescape(params[:miner_id])
      halt 404 unless miner_configured?(miner_id)

      command = params[:command].to_s
      halt 422, "invalid command: #{command}" unless ADMIN_RAW_COMMAND_PATTERN.match?(command)

      log_admin_command('admin.raw_command', command: command, args: params[:args].to_s, scope: miner_id)
      started = Time.now
      result  = build_commander_for([miner_id]).raw!(command: command, args: params[:args])
      log_admin_result("raw:#{command}", miner_id, result, started)
      render_admin_result(result)
    end

    post '/miner/:miner_id/admin/:command' do
      miner_id = CGI.unescape(params[:miner_id])
      halt 404 unless miner_configured?(miner_id)

      command = params[:command].to_s
      halt 404 unless ALLOWED_ADMIN_QUERIES.include?(command) || ALLOWED_ADMIN_WRITES.include?(command)

      log_admin_command('admin.command', command: command, scope: miner_id)
      started   = Time.now
      commander = build_commander_for([miner_id])
      result =
        if ALLOWED_ADMIN_QUERIES.include?(command)
          commander.public_send(command)
        else
          commander.public_send("#{command}!")
        end
      log_admin_result(command, miner_id, result, started)
      render_admin_result(result)
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

    get '/graph_data/:metric' do
      projection = GRAPH_METRIC_PROJECTIONS[params[:metric]]
      halt 404 unless projection

      envelope = monitor_client.graph_data(metric: params[:metric],
                                           miner_id: nil,
                                           since: params[:since])

      fields  = envelope[:fields] || []
      rows    = envelope[:data]   || []
      indices = projection.map { |f| fields.index(f) }

      content_type :json
      JSON.generate(rows.map { |row| indices.map { |i| i ? row[i] : nil } })
    end

    get '/healthz' do
      reasons = []

      begin
        configured_miners
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
      configured_miners.each do |host, port, _label|
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
      @monitor_client ||= MonitorClient.new(base_url: settings.monitor_url,
                                            timeout_ms: settings.monitor_timeout_ms || 2000)
    end
  end
end
