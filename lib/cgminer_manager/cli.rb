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
      when 'version' then cmd_version
      else
        warn "unknown verb: #{verb.inspect}"
        warn 'usage: cgminer_manager {run|doctor|version}'
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
