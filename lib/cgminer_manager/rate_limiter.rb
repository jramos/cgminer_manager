# frozen_string_literal: true

require 'ipaddr'

module CgminerManager
  # Rack middleware that gates POST requests to admin + write paths
  # against a per-IP fixed-window counter. Returns 429 + Retry-After
  # when the limit is exceeded. No-op for GET / non-matching paths.
  #
  # Fixed window, not sliding: when `window_seconds` elapses from a
  # bucket's `window_start`, count resets. Edge cases at window
  # boundaries can see up to 2x the configured limit in a ~2-second
  # band. Acceptable for defense-in-depth; upgrade to a ring-buffer
  # sliding-log if tighter bounds are ever needed.
  #
  # State is in-process (Hash + Mutex). Single-Puma-process deployments
  # only; cluster-mode Puma would need a shared store (Redis, etc.) that
  # this class intentionally does not have. `@buckets` grows by one
  # entry per unique client IP and never shrinks; on the order of 200
  # bytes per entry, so 10k distinct IPs is ~2 MB. The XFF garbage
  # fallback (see `client_ip`) bounds keys to well-formed IP strings so
  # an attacker cannot amplify memory use via malformed headers.
  class RateLimiter
    # Matches all rate-limited POST routes in HttpApp:
    # - /manager/manage_pools
    # - /miner/:miner_id/manage_pools
    # - /manager/admin/...
    # - /miner/:miner_id/admin/...
    # - /miner/:miner_id/maintenance — write to RestartStore
    DEFAULT_PATHS = %r{\A/(?:manager|miner/[^/]+)/(?:admin(?:/|\z)|manage_pools\z|maintenance(?:/|\z))}

    def initialize(app, requests:, window_seconds:, paths: DEFAULT_PATHS, trusted_proxies: [])
      @app = app
      @requests = requests
      @window_seconds = window_seconds
      @paths = paths
      @trusted_proxies = trusted_proxies
      @buckets = {}
      @mutex = Mutex.new
    end

    def call(env)
      return @app.call(env) unless applies?(env)

      ip = client_ip(env)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      allowed, retry_after = check_bucket(ip, now)
      return @app.call(env) if allowed

      log_exceeded(ip, env['PATH_INFO'], retry_after, env[CgminerManager::RequestId::ENV_KEY])
      too_many_requests(retry_after)
    end

    private

    def applies?(env)
      env['REQUEST_METHOD'] == 'POST' && env['PATH_INFO'] =~ @paths
    end

    # Canonical X-Forwarded-For trust walk:
    # 1. If no trusted proxies configured, or REMOTE_ADDR isn't one,
    #    use REMOTE_ADDR (XFF is attacker-forgeable and ignored).
    # 2. Otherwise walk XFF right-to-left. Return the first hop that
    #    parses AND isn't itself a trusted proxy -- that's the claimed
    #    client.
    # 3. If a candidate fails to parse (attacker-supplied garbage),
    #    fall back to REMOTE_ADDR rather than treat garbage as the
    #    client IP. Otherwise each distinct garbage string would
    #    create a new bucket and amplify memory use.
    # 4. If every XFF hop is trusted or unparseable, fall back to
    #    REMOTE_ADDR (the nearest trusted proxy). This degrades to
    #    global throttling under a misconfigured proxy chain.
    def client_ip(env)
      remote = env['REMOTE_ADDR']
      return remote if @trusted_proxies.empty? || !proxy_trusted?(remote)

      walk_xff(env['HTTP_X_FORWARDED_FOR']) || remote
    end

    # Walk the X-Forwarded-For header right-to-left, return the first
    # hop that parses AND isn't a trusted proxy. Returns nil if the
    # header is absent, if a hop fails to parse (garbage fallback), or
    # if every hop is itself a trusted proxy -- caller falls back to
    # REMOTE_ADDR in those cases.
    def walk_xff(xff)
      return nil if xff.nil? || xff.empty?

      xff.split(',').map(&:strip).reverse.each do |candidate|
        return nil unless (parsed = parse_ip(candidate))
        return candidate unless trusted_proxy_for?(parsed)
      end
      nil
    end

    def proxy_trusted?(ip_string)
      parsed = parse_ip(ip_string)
      return false if parsed.nil?

      trusted_proxy_for?(parsed)
    end

    def trusted_proxy_for?(parsed_ip)
      @trusted_proxies.any? { |cidr| cidr.include?(parsed_ip) }
    end

    def parse_ip(ip_string)
      return nil if ip_string.nil? || ip_string.empty?

      IPAddr.new(ip_string)
    rescue IPAddr::Error
      nil
    end

    # All access to @buckets goes through @mutex.synchronize. Hash is
    # not itself thread-safe for concurrent write.
    def check_bucket(ip, now)
      @mutex.synchronize do
        bucket = @buckets[ip]
        if bucket.nil? || now - bucket[:window_start] >= @window_seconds
          @buckets[ip] = { count: 1, window_start: now }
          return [true, 0]
        end

        # Check before increment: a rejected request must not inflate
        # the stored counter indefinitely.
        if bucket[:count] >= @requests
          retry_after = (@window_seconds - (now - bucket[:window_start])).ceil
          retry_after = 1 if retry_after < 1
          return [false, retry_after]
        end

        bucket[:count] += 1
        [true, 0]
      end
    end

    def log_exceeded(ip, path, retry_after, request_id)
      Logger.warn(
        event: 'rate_limit.exceeded',
        request_id: request_id,
        remote_ip: ip,
        path: path,
        retry_after: retry_after
      )
    end

    def too_many_requests(retry_after)
      [429,
       { 'Content-Type' => 'text/plain', 'Retry-After' => retry_after.to_s },
       ["Too Many Requests. Retry after #{retry_after}s.\n"]]
    end
  end
end
