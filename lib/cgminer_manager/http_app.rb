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
    # The singleton RestartStore. Server#configure_http_app builds it
    # once and writes it here so that HTTP request handlers and the
    # RestartScheduler thread share one mutex-bearing instance —
    # otherwise concurrent UI POSTs and scheduler ticks would each hold
    # their own mutex and racing writes would tear.
    set :restart_store,           nil
    # Singleton in-process ConfirmationStore for the v1.7.0 two-step
    # destructive-command flow. Process-local; cluster mode would
    # silently drop tokens on worker hop (boot warn fires from Config
    # in that posture).
    set :confirmation_store,      ConfirmationStore.new
    # Default-on per the locked plan; opt out via
    # CGMINER_MANAGER_REQUIRE_CONFIRM=off. Server#configure_http_app
    # plumbs the parsed Config value here.
    set :confirmation_required,   true

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
    private_class_method :validate_miners_shape!

    # Re-parses `settings.miners_file` and atomically swaps
    # `settings.configured_miners`. Returns the new miner count on
    # success, nil on parse/validation/IO failure — on failure the
    # old setting is untouched so in-flight readers never see a torn
    # state. Callers distinguish success from no-op by the return
    # value.
    def self.reload_miners!
      path = settings.miners_file
      new_miners = parse_miners_file(path)
      set :configured_miners, new_miners
      new_miners.size
    rescue ConfigError, Errno::ENOENT, Psych::SyntaxError => e
      Logger.warn(event: 'reload.failed',
                  error: e.class.to_s, message: e.message)
      nil
    end

    # Spec harness. Preserves the existing public signature so no spec
    # file needs to change. Eagerly parses miners_file into the setting
    # so specs don't rely on a later lazy load.
    def self.configure_for_test!(monitor_url:, miners_file:, # rubocop:disable Metrics/ParameterLists
                                 stale_threshold_seconds: 300,
                                 pool_thread_cap: 8,
                                 monitor_timeout_ms: 2000,
                                 session_secret: 'x' * 64,
                                 production: false,
                                 rate_limit_enabled: false,
                                 rate_limit_requests: 60,
                                 rate_limit_window_seconds: 60,
                                 trusted_proxies: [],
                                 restart_store: nil)
      set :monitor_url,             monitor_url
      set :miners_file,             miners_file
      set :configured_miners,       parse_miners_file(miners_file)
      set :stale_threshold_seconds, stale_threshold_seconds
      set :pool_thread_cap,         pool_thread_cap
      set :monitor_timeout_ms,      monitor_timeout_ms
      set :session_secret,          session_secret
      set :production,              production
      set :rate_limit_enabled,        rate_limit_enabled
      set :rate_limit_requests,       rate_limit_requests
      set :rate_limit_window_seconds, rate_limit_window_seconds
      set :trusted_proxies,           trusted_proxies
      set :restart_store,             restart_store
      set :confirmation_store,        ConfirmationStore.new
      set :confirmation_required,     false # specs opt in per-example via configure_confirmation_for_test!
      install_middleware!
    end

    # Spec helper to flip require_confirm without rebuilding the whole
    # test config. Used by integration specs that exercise the two-step
    # flow.
    def self.configure_confirmation_for_test!(required:)
      set :confirmation_required, required
      set :confirmation_store, ConfirmationStore.new
    end

    helpers Sinatra::ContentFor
    helpers ConfirmationHelpers

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

    # Rate-limit defaults. install_middleware! consults these; Server
    # and configure_for_test! override them with the operator's config
    # before calling install_middleware!.
    set :rate_limit_enabled, true
    set :rate_limit_requests, 60
    set :rate_limit_window_seconds, 60
    set :trusted_proxies, []

    before do
      @request_started_at = Time.now
      # RequestId middleware (top of stack) populates this for every
      # request — admin and non-admin alike. Read from env so RateLimiter
      # and AdminAuth (which fire BEFORE this filter) can already have
      # tagged their events with the same value.
      @request_id = request.env[CgminerManager::RequestId::ENV_KEY]
    end

    after do
      Logger.info(event: 'http.request',
                  request_id: @request_id,
                  path: request.path,
                  method: request.request_method,
                  status: response.status,
                  duration_ms: ((Time.now - @request_started_at) * 1000).round)
    end

    # Wires the session-cookie + admin-auth + CSRF middleware stack.
    # Server#configure_http_app (and configure_for_test!) calls this
    # AFTER the Sinatra settings are populated, so
    # `settings.session_secret` and `settings.production` actually
    # reflect the operator's configuration when captured by `use`
    # middleware. Sinatra's `use` stores args by value at call time;
    # declaring this stack in a class-body `configure do … end` block
    # would freeze `nil` / `false` before Server#configure_http_app ever
    # runs, silently discarding CGMINER_MANAGER_SESSION_SECRET. Idempotent:
    # @middleware is re-seeded each call so repeated invocations in
    # tests (configure_for_test!) don't pile up duplicate middleware.
    def self.install_middleware!
      # Reset the middleware stack. Sinatra appends to `@middleware`
      # each `use` call and builds the Rack stack lazily on first
      # request; if we `use` on every configure_for_test! without
      # resetting, every test example stacks another copy of the
      # session + auth + CSRF middleware, turning each request into
      # an ever-deeper onion.
      @middleware = []

      # RequestId sits at the very top of the stack so RateLimiter and
      # AdminAuth (which fire before any Sinatra filter) can read the
      # request_id from env when emitting their events.
      use CgminerManager::RequestId

      # RateLimiter sits ABOVE session + auth on purpose: a 401-probing
      # attacker must be throttled before AdminAuth executes, otherwise
      # the probe rate is unbounded.
      if settings.rate_limit_enabled
        use CgminerManager::RateLimiter,
            requests: settings.rate_limit_requests,
            window_seconds: settings.rate_limit_window_seconds,
            trusted_proxies: settings.trusted_proxies
      end

      use Rack::Session::Cookie,
          key: 'cgminer_manager.session',
          secret: settings.session_secret || SecureRandom.hex(32),
          same_site: :lax,
          # Gate on production so dev/test over plain HTTP on 127.0.0.1
          # keeps working. Operators running in production are expected
          # to terminate TLS at a reverse proxy per the README security
          # posture; this prevents the session cookie from being sent
          # back over a non-HTTPS hop.
          secure: settings.production
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

      def admin_path?(path)
        path.match?(%r{\A/(?:manager|miner/[^/]+)/(?:admin(?:/|\z)|maintenance(?:/|\z))})
      end

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
        ViewModels.build_view_miner_pool(monitor_miners, configured_miners: configured_miners)
      end

      # Fail-loud accessor — an unconfigured App raises a clear error
      # rather than silently returning an empty miners list or NoMethodError
      # when routes try to iterate it. Raises ConfigError so it routes
      # through the CLI's exit-2 path (cli.rb) like every other
      # config-time invariant in this codebase.
      def configured_miners
        settings.configured_miners || raise(
          CgminerManager::ConfigError,
          'HttpApp not configured; call Server#configure_http_app or configure_for_test!'
        )
      end

      def configured_labels_by_id
        ViewModels.configured_labels_by_id(configured_miners)
      end

      # Variant for the per-miner page, where we only need to thread the
      # configured miner list into @miner_pool for any partial that reaches
      # for it. Monitor availability isn't fetched separately here.
      def build_view_miner_pool_from_yml
        ViewModels.build_view_miner_pool_from_yml(configured_miners: configured_miners)
      end

      def build_dashboard_view_model
        ViewModels.build_dashboard(
          monitor_client: monitor_client,
          configured_miners: configured_miners,
          stale_threshold_seconds: settings.stale_threshold_seconds,
          pool_thread_cap: settings.pool_thread_cap
        )
      end

      def miner_configured?(miner_id)
        ViewModels.miner_configured?(miner_id, configured_miners: configured_miners)
      end

      def neighbor_urls(miner_id)
        prev_id, next_id = ViewModels.neighbor_ids(miner_id, configured_miners: configured_miners)
        [prev_id && miner_url(prev_id), next_id && miner_url(next_id)]
      end

      def build_miner_view_model(miner_id)
        ViewModels.build_miner_view_model(miner_id: miner_id, monitor_client: monitor_client)
      end

      def build_pool_manager_for_all
        FleetBuilders.pool_manager_for_all(
          configured_miners: configured_miners,
          thread_cap: settings.pool_thread_cap,
          request_id: @request_id
        )
      end

      def build_pool_manager_for(miner_ids)
        FleetBuilders.pool_manager_for(miner_ids, request_id: @request_id)
      end

      def build_commander_for_all
        FleetBuilders.commander_for_all(
          configured_miners: configured_miners,
          thread_cap: settings.pool_thread_cap,
          request_id: @request_id
        )
      end

      def build_commander_for(miner_ids)
        FleetBuilders.commander_for(miner_ids,
                                    thread_cap: settings.pool_thread_cap,
                                    request_id: @request_id)
      end

      def admin_session_id_hash
        AdminLogging.session_id_hash(request.env['rack.session']&.id)
      end

      def log_admin_command(event, **extra)
        Logger.info(**AdminLogging.command_log_entry(
          event: event,
          command: extra.delete(:command),
          scope: extra.delete(:scope),
          request_id: @request_id,
          session_id_hash: admin_session_id_hash,
          remote_ip: request.ip,
          user_agent: request.user_agent,
          user: request.env['cgminer_manager.admin_user'],
          **extra
        ))
      end

      def log_admin_result(command, scope, result, started_at)
        Logger.info(**AdminLogging.result_log_entry(
          command: command, scope: scope, result: result,
          started_at: started_at, request_id: @request_id
        ))
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

      # Dispatches a typed-allowlist admin command (read-only or
      # destructive write) for the given scope. Extracted from the
      # POST /manager/admin/:command and POST /miner/:id/admin/:command
      # routes so the gate-eligible fleet-wide variant can wrap it in
      # start_or_dispatch_destructive without duplicating logic.
      def dispatch_typed_admin(command, scope)
        log_admin_command('admin.command', command: command, scope: scope)
        started   = Time.now
        commander = scope == 'all' ? build_commander_for_all : build_commander_for([scope])
        result =
          if ALLOWED_ADMIN_QUERIES.include?(command)
            commander.public_send(command)
          else
            commander.public_send("#{command}!")
          end
        log_admin_result(command, scope, result, started)
        render_admin_result(result)
      end

      # Mirror for raw /run dispatch — same extraction reasoning.
      def dispatch_raw_admin(command, scope, args)
        log_admin_command('admin.raw_command', command: command, args: args, scope: scope)
        started = Time.now
        commander = scope == 'all' ? build_commander_for_all : build_commander_for([scope])
        result = commander.raw!(command: command, args: args)
        log_admin_result("raw:#{command}", scope, result, started)
        render_admin_result(result)
      end

      # Replays a confirmed pending Entry by route_kind. Called from
      # POST /manager/admin/confirm/:token after consume_confirmation_or_halt
      # returns the Entry. Pin the dispatch to the originally-stored
      # command/scope/args verbatim so a re-render of the form between
      # step 1 and step 2 can't mutate the action.
      def dispatch_confirmed_entry(entry)
        case entry.route_kind
        when :typed_command
          dispatch_typed_admin(entry.command, entry.scope)
        when :raw_run
          dispatch_raw_admin(entry.command, entry.scope, entry.args.to_s)
        when :manage_pools
          replay_manage_pools(entry)
        else
          halt 500, "unknown route_kind: #{entry.route_kind}"
        end
      end

      def replay_manage_pools(entry)
        a = entry.args || {}
        params[:url]  = a[:url]
        params[:user] = a[:user]
        params[:pass] = a[:pass]
        pm = build_pool_manager_for_all
        @result = dispatch_pool_action(pm, a[:action_name], a[:pool_index])
        render_partial('shared/manage_pools')
      end

      # Load the schedule for one miner, or build a default-disabled
      # schedule when no store is configured (tests that don't pass
      # restart_store: into configure_for_test! still render the show
      # page) or no entry exists yet for this miner.
      def load_maintenance_schedule(miner_id)
        store = settings.restart_store
        existing = store&.load&.[](miner_id)
        existing || RestartSchedule.build(
          miner_id: miner_id, enabled: false, time_utc: nil,
          last_restart_at: nil, last_scheduled_date_utc: nil
        )
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
      @bad_chain_elements   = []
      @maintenance_schedule = load_maintenance_schedule(miner_host_port)
      haml :'miner/show'
    end

    post '/manager/manage_pools' do
      action_name = params[:action_name].to_s
      pool_index  = params[:pool_index].to_i

      args = { action_name: action_name, pool_index: pool_index,
               url: params[:url], user: params[:user], pass: params[:pass] }

      start_or_dispatch_destructive(route_kind: :manage_pools, command: action_name,
                                    scope: 'all', args: args) do
        pm = build_pool_manager_for_all
        @result = dispatch_pool_action(pm, action_name, pool_index)
        render_partial('shared/manage_pools')
      end
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

      args = params[:args].to_s

      # Per decisions #3 + #4: only fleet-wide raw runs gate; per-miner
      # scopes skip the dance (single-rig blast radius).
      if scope == 'all'
        start_or_dispatch_destructive(route_kind: :raw_run, command: command,
                                      scope: scope, args: args) do
          dispatch_raw_admin(command, scope, args)
        end
      else
        dispatch_raw_admin(command, scope, args)
      end
    end

    post '/manager/admin/:command' do
      command = params[:command].to_s
      halt 404 unless ALLOWED_ADMIN_QUERIES.include?(command) || ALLOWED_ADMIN_WRITES.include?(command)

      # Read-only typed verbs never gate (decision #4); only the four
      # destructive writes (restart/quit/zero/save) gate at the
      # fleet-wide route.
      if ALLOWED_ADMIN_WRITES.include?(command)
        start_or_dispatch_destructive(route_kind: :typed_command, command: command,
                                      scope: 'all') do
          dispatch_typed_admin(command, 'all')
        end
      else
        dispatch_typed_admin(command, 'all')
      end
    end

    # ----- Two-step confirmation flow endpoints (v1.7.0+) -----
    # No GET /manager/admin/confirm/:token — token must never appear
    # in a URL bar (decision #8). The JS-off fallback page is rendered
    # IN the 202 response body of the original destructive POST.

    post '/manager/admin/confirm/:token' do
      entry = consume_confirmation_or_halt(params[:token])
      started_age_ms = ((Time.now.utc - entry.created_at) * 1000).round
      Logger.info(**AdminLogging.action_confirmed_log_entry(
        token: entry.token, command: entry.command, scope: entry.scope,
        request_id: confirmation_request_id,
        session_id_hash: confirmation_session_id_hash,
        remote_ip: request.ip, user_agent: request.user_agent,
        user: confirmation_user,
        started_age_ms: started_age_ms,
        route_kind: entry.route_kind, args: entry.args
      ))
      dispatch_confirmed_entry(entry)
    end

    delete '/manager/admin/confirm/:token' do
      result = settings.confirmation_store.cancel(params[:token],
                                                  confirmation_session_id_hash)
      if result.is_a?(ConfirmationStore::Entry)
        Logger.info(**AdminLogging.action_cancelled_log_entry(
          token: result.token, command: result.command, scope: result.scope,
          request_id: confirmation_request_id,
          session_id_hash: confirmation_session_id_hash,
          user: confirmation_user
        ))
        status 204
      else
        Logger.warn(**AdminLogging.action_rejected_log_entry(
          reason: result, token: params[:token],
          request_id: confirmation_request_id,
          session_id_hash: confirmation_session_id_hash,
          user: confirmation_user
        ))
        halt(result == :session_mismatch ? 403 : 404)
      end
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

    get '/miner/:miner_id/maintenance' do
      miner_id = CGI.unescape(params[:miner_id])
      halt 404 unless miner_configured?(miner_id)

      @miner_host_port      = miner_id
      @maintenance_schedule = load_maintenance_schedule(miner_id)
      render_partial('miner/maintenance')
    end

    post '/miner/:miner_id/maintenance' do
      miner_id = CGI.unescape(params[:miner_id])
      halt 404 unless miner_configured?(miner_id)
      halt 503, 'restart store not configured' unless settings.restart_store

      attrs = {
        'miner_id' => miner_id,
        'enabled' => params[:enabled].to_s == '1',
        'time_utc' => params[:time_utc].to_s.empty? ? nil : params[:time_utc].to_s
      }

      begin
        new_schedule = RestartSchedule.parse(attrs)
      rescue RestartSchedule::InvalidError => e
        @miner_host_port       = miner_id
        @maintenance_schedule  = load_maintenance_schedule(miner_id)
        @maintenance_error_msg = e.message
        log_admin_command('admin.maintenance.invalid', command: 'maintenance',
                                                       scope: miner_id, error: e.message)
        status 422
        return render_partial('miner/maintenance')
      end

      settings.restart_store.update(miner_id) do |existing|
        new_schedule.with(
          last_restart_at: existing&.last_restart_at,
          last_scheduled_date_utc: existing&.last_scheduled_date_utc
        )
      end

      log_admin_command('admin.maintenance.updated', command: 'maintenance',
                                                     scope: miner_id,
                                                     enabled: attrs['enabled'],
                                                     time_utc: attrs['time_utc'])

      @miner_host_port      = miner_id
      @maintenance_schedule = load_maintenance_schedule(miner_id)
      render_partial('miner/maintenance')
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

    # Public read view of every miner's RestartSchedule. Consumed by
    # cgminer_monitor (CGMINER_MONITOR_RESTART_SCHEDULE_URL) so the
    # AlertEvaluator can suppress the `offline` rule during a scheduled
    # restart window. Unauthenticated by design — mirrors /api/v1/ping.json
    # and avoids dragging monitor into BasicAuth handling. Returns an
    # empty schedule list if the store is unconfigured.
    get '/api/v1/restart_schedules.json' do
      content_type :json

      schedules = settings.restart_store&.load || {}
      payload = {
        schedules: schedules.values.map(&:to_h),
        generated_at: Time.now.utc.iso8601
      }
      JSON.generate(payload)
    end

    get '/api/v1/ping.json' do
      content_type :json

      available = 0
      unavailable = 0
      on_wire = FleetBuilders.build_wire_logger(@request_id)
      configured_miners.each do |host, port, _label|
        miner = CgminerApiClient::Miner.new(host, port, on_wire: on_wire)
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
                                            timeout_ms: settings.monitor_timeout_ms,
                                            request_id: @request_id)
    end
  end
end
