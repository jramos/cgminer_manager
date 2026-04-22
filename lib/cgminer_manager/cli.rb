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

    def cmd_version
      puts CgminerManager::VERSION
      0
    end

    # Dry-run-parses miners.yml locally so typos surface at the
    # operator's terminal (exit 2 via ConfigError rescue above) instead
    # of in the server's logs, then sends SIGHUP to the PID recorded
    # by a running `cgminer_manager run`. Operators can also skip this
    # verb and `kill -HUP <pid>` directly.
    def cmd_reload
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
