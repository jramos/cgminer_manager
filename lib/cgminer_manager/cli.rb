# frozen_string_literal: true

module CgminerManager
  class CLI
    def self.run(argv)
      new.run(argv)
    end

    def run(argv)
      verb = argv.shift
      case verb
      when 'run'     then cmd_run
      when 'doctor'  then cmd_doctor
      when 'reload'  then cmd_reload
      when 'version' then cmd_version
      else
        warn "unknown verb: #{verb.inspect}"
        warn 'usage: cgminer_manager {run|doctor|reload|version}'
        64
      end
    rescue ConfigError => e
      warn "config error: #{e.message}"
      2
    end

    private

    def cmd_run
      config = Config.from_env
      Logger.format = config.log_format
      Logger.level  = config.log_level
      Server.new(config).run
    end

    def cmd_doctor
      config = Config.from_env
      failures = []

      monitor_miners = check_monitor(config, failures)
      check_miners(config, monitor_miners, failures)
      report_admin_auth_posture(failures)
      report_pid_file_posture(failures)
      report_rate_limit_posture(config)
      report_trusted_proxies_posture(config)

      if failures.empty?
        puts 'doctor: all checks passed'
        0
      else
        failures.each { |f| warn "  FAIL: #{f}" }
        1
      end
    end

    # Mirrors AdminAuth#call's precedence: creds-set always engages the
    # gate, so a stale =off with creds set is still "required" — not
    # "disabled". Without this symmetry, doctor would lie to audits.
    def report_admin_auth_posture(failures)
      user = ENV['CGMINER_MANAGER_ADMIN_USER'].to_s
      pass = ENV['CGMINER_MANAGER_ADMIN_PASSWORD'].to_s
      if !user.empty? && !pass.empty?
        puts '  admin auth: required (credentials configured)'
      elsif ENV['CGMINER_MANAGER_ADMIN_AUTH'] == 'off'
        puts '  admin auth: DISABLED (CGMINER_MANAGER_ADMIN_AUTH=off)'
      else
        failures << 'admin auth misconfigured: no credentials and no escape hatch'
      end
    end

    # Same audit-honest treatment as admin-auth posture: explicitly
    # report whether the PID file exists and whether the recorded PID
    # is alive, so an operator reading `doctor` output knows whether
    # `cgminer_manager reload` will work. A configured-but-missing or
    # stale file is a failure (exit 1).
    def report_pid_file_posture(failures)
      path = ENV.fetch('CGMINER_MANAGER_PID_FILE', nil)
      if path.nil? || path.empty?
        puts '  pid file: not configured'
        return
      end

      unless File.exist?(path)
        failures << "pid file configured but missing: #{path}"
        return
      end

      pid = Integer(File.read(path).strip)
      Process.kill(0, pid)
      puts "  pid file: OK (pid #{pid})"
    rescue ArgumentError
      failures << "pid file is not an integer: #{path}"
    rescue Errno::ESRCH
      failures << "pid file: STALE (pid in #{path} not running)"
    rescue Errno::EPERM
      failures << "pid file: pid in #{path} exists but is not owned by us"
    end

    def report_rate_limit_posture(config)
      if config.rate_limit_enabled
        puts "  rate-limit: enabled (#{config.rate_limit_requests} req / " \
             "#{config.rate_limit_window_seconds}s per IP)"
      else
        puts '  rate-limit: DISABLED (CGMINER_MANAGER_RATE_LIMIT=off)'
      end
    end

    def report_trusted_proxies_posture(config)
      if config.trusted_proxies.empty?
        puts '  trusted-proxies: none (X-Forwarded-For ignored)'
      else
        # IPAddr#to_s drops the prefix; format "addr/prefix" for operator clarity.
        display = config.trusted_proxies.map { |cidr| "#{cidr}/#{cidr.prefix}" }
        puts "  trusted-proxies: #{display.join(', ')}"
      end
    end

    def cmd_version
      puts CgminerManager::VERSION
      0
    end

    # Dry-run-parses miners.yml locally so typos surface at the
    # operator's terminal (exit 2 via ConfigError rescue above) instead
    # of in the server's logs, then sends SIGHUP to the PID recorded
    # by a running `cgminer_manager run`. Operators can also skip this
    # verb and `kill -HUP <pid>` directly.
    def cmd_reload # rubocop:disable Metrics/MethodLength
      config   = Config.from_env
      pid_path = config.pid_file
      if pid_path.nil? || pid_path.empty?
        raise ConfigError,
              'CGMINER_MANAGER_PID_FILE not set; cannot locate running server'
      end

      begin
        HttpApp.parse_miners_file(config.miners_file)
      rescue Psych::SyntaxError => e
        raise ConfigError, "miners_file is not valid YAML: #{e.message}"
      end

      pid = Integer(File.read(pid_path).strip)
      Process.kill(0, pid) # probe alive; raises Errno::ESRCH if dead
      Process.kill('HUP', pid)
      puts "SIGHUP sent to pid #{pid}; check server logs for reload.ok"
      0
    rescue Errno::ENOENT
      warn "pid file not found: #{pid_path} " \
           '(server may still be starting — pid file is written after Puma boots)'
      1
    rescue Errno::ESRCH
      warn "stale pid file (pid not running): #{pid_path}"
      1
    rescue Errno::EPERM
      warn "pid #{pid} exists but is not owned by us " \
           "(stale pid file from a different user? #{pid_path})"
      1
    rescue ArgumentError
      warn "pid file is not an integer: #{pid_path}"
      1
    end

    def check_monitor(config, failures)
      client = MonitorClient.new(base_url: config.monitor_url, timeout_ms: config.monitor_timeout)
      monitor_miners = client.miners[:miners]
      puts "  monitor /v2/miners: OK (#{monitor_miners.size} miner(s))"
      monitor_miners
    rescue MonitorError => e
      failures << "monitor unreachable: #{e.message}"
      nil
    end

    def check_miners(config, monitor_miners, failures)
      config.load_miners.each do |host, port|
        id = "#{host}:#{port}"
        if CgminerApiClient::Miner.new(host, port).available?
          puts "  cgminer #{id}: reachable"
        else
          failures << "cgminer #{id} unreachable"
        end

        next unless monitor_miners

        unless monitor_miners.any? { |m| m[:id] == id }
          failures << "miner #{id} in miners.yml but not in monitor /v2/miners"
        end
      end
    end
  end
end
