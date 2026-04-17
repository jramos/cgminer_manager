# frozen_string_literal: true

# Launches one FakeCgminer TCP listener per miner in Scenario::MINERS,
# each bound to the scenario-declared loopback port. Keeps the harness
# deterministic (no per-endpoint env-var shortcut) while letting the
# screenshot manager exercise the full Admin surface end-to-end.
#
# Run:
#   ruby dev/screenshots/fake_cgminer_fleet.rb
#
# Stops on SIGINT/SIGTERM (also wired by boot.sh's pidfile teardown).

$LOAD_PATH.unshift(File.expand_path('../../spec/support', __dir__))

require 'fake_cgminer'
require 'cgminer_fixtures'
require_relative 'scenario'

def responses_for(spec)
  when_ts = Scenario::NOW.to_i
  ok = lambda do |code, msg|
    %({"STATUS":[{"STATUS":"S","When":#{when_ts},"Code":#{code},"Msg":"#{msg}",) +
      %("Description":"cgminer 4.11.1"}],"id":1})
  end

  {
    'privileged' => ok.call(46, 'Privileged access OK'),
    'version'    => ok.call(22, 'CGMiner versions').sub('}]', %(}],"VERSION":[{"CGMiner":"4.11.1","API":"3.7"}])),
    'stats'      => ok.call(70, 'CGMiner stats'),
    'devs'       => ok.call(9, "1 #{spec[:chain_prefix]}"),
    'summary'    => ok.call(11, 'Summary'),
    'pools'      => ok.call(7, '2 Pool(s)'),
    'zero'       => ok.call(72, 'zeroed all stats'),
    'save'       => ok.call(20, 'Configuration saved'),
    'restart'    => ok.call(42, 'cgminer restarting'),
    'quit'       => ok.call(42, 'cgminer shutting down'),
    # Pool-management verbs used by the manage_pools UI (via PoolManager).
    'disablepool' => ok.call(47, 'Pool disabled'),
    'enablepool'  => ok.call(47, 'Pool enabled'),
    'removepool'  => ok.call(47, 'Pool removed'),
    'addpool'     => ok.call(55, "Added pool 'x'"),
    # Hardware-tuning verb — only reachable via the raw RPC form with
    # a single-miner scope. Canned success so screenshots can demo it.
    'pgaset'      => ok.call(72, 'PGA 0 set clock 690')
  }
end

servers = Scenario::MINERS.map do |spec|
  responses = responses_for(spec)
  server = FakeCgminer.new(responses: responses, port: spec[:port]).start
  warn "listening on 127.0.0.1:#{server.port} (label=#{spec[:label]}, model=#{spec[:model]})"
  server
end

shutdown = lambda do
  warn 'stopping fake cgminer fleet'
  servers.each(&:stop)
  exit 0
end

trap(:INT,  &shutdown)
trap(:TERM, &shutdown)

sleep
