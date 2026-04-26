# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CgminerManager::AdminLogging do
  describe '.session_id_hash' do
    it 'returns a 12-char hex digest of the session id' do
      hash = described_class.session_id_hash('a-full-rack-session-id')
      expect(hash).to match(/\A[0-9a-f]{12}\z/)
    end

    it 'returns a stable 12-char digest for a nil session id' do
      hash = described_class.session_id_hash(nil)
      expect(hash).to match(/\A[0-9a-f]{12}\z/)
    end
  end

  describe '.command_log_entry' do
    let(:entry) do
      described_class.command_log_entry(
        event: 'admin.raw_command', command: 'version', scope: 'all',
        request_id: 'req-123', session_id_hash: 'abc123abc123',
        remote_ip: '127.0.0.1', user_agent: 'curl/8', user: 'operator',
        args: 'foo,bar'
      )
    end

    it 'carries the fixed keys' do
      expect(entry).to include(
        event: 'admin.raw_command', request_id: 'req-123',
        user: 'operator', remote_ip: '127.0.0.1', user_agent: 'curl/8',
        session_id_hash: 'abc123abc123', command: 'version', scope: 'all'
      )
    end

    it 'merges **extra AFTER the fixed keys so args:/scope: callers survive' do
      expect(entry[:args]).to eq('foo,bar')
    end
  end

  describe '.result_log_entry' do
    it 'pulls ok_count/failed_count/failed_codes off a FleetWriteResult-shaped value' do
      result = instance_double(CgminerManager::FleetWriteResult,
                               ok_count: 3, failed_count: 1,
                               failed_codes_count_map: { access_denied: 1 })
      started = Time.now - 0.25
      entry = described_class.result_log_entry(
        command: 'restart', scope: 'all', result: result,
        started_at: started, request_id: 'req-123'
      )
      expect(entry).to include(
        event: 'admin.result',
        request_id: 'req-123',
        command: 'restart',
        scope: 'all',
        ok_count: 3,
        failed_count: 1,
        failed_codes: { access_denied: 1 }
      )
      expect(entry[:duration_ms]).to be_between(200, 2000)
    end

    it 'always emits failed_codes (empty hash when nothing failed)' do
      result = instance_double(CgminerManager::FleetWriteResult,
                               ok_count: 3, failed_count: 0,
                               failed_codes_count_map: {})
      entry = described_class.result_log_entry(
        command: 'restart', scope: 'all', result: result,
        started_at: Time.now, request_id: 'req-zzz'
      )
      expect(entry).to have_key(:failed_codes)
      expect(entry[:failed_codes]).to eq({})
    end
  end

  describe '.action_started_log_entry (v1.7.0+)' do
    let(:expires_at) { Time.utc(2026, 4, 26, 12, 5, 30, 123_000) }

    it 'carries the fixed keys including the ISO8601 expires_at' do
      entry = described_class.action_started_log_entry(
        token: 'tok-1', expires_at: expires_at,
        command: 'restart', scope: 'all',
        request_id: 'req-1', session_id_hash: 'sess-1',
        remote_ip: '127.0.0.1', user_agent: 'curl/8', user: 'op'
      )
      expect(entry).to include(
        event: 'admin.action_started',
        confirmation_token: 'tok-1',
        expires_at: '2026-04-26T12:05:30.123Z',
        command: 'restart', scope: 'all',
        request_id: 'req-1', session_id_hash: 'sess-1',
        user: 'op'
      )
    end

    it 'redacts manage_pools/add credentials in the args field' do
      entry = described_class.action_started_log_entry(
        token: 'tok-2', expires_at: expires_at,
        command: 'add', scope: 'all',
        request_id: 'req-2', session_id_hash: 'sess-2',
        remote_ip: '127.0.0.1', user_agent: 'curl/8',
        route_kind: :manage_pools,
        args: { url: 'stratum+tcp://pool.example:3333', user: 'worker', pass: 'sekrit' }
      )
      expect(entry[:args]).to eq('[REDACTED: pool credentials]')
    end

    it 'passes raw_run args through unredacted (operator on the hook for what they typed)' do
      entry = described_class.action_started_log_entry(
        token: 'tok-3', expires_at: expires_at,
        command: 'pgaset', scope: 'all',
        request_id: 'req-3', session_id_hash: 'sess-3',
        remote_ip: '127.0.0.1', user_agent: 'curl/8',
        route_kind: :raw_run, args: '0,clock,500'
      )
      expect(entry[:args]).to eq('0,clock,500')
    end

    it 'leaves args nil when not provided (typed_command writes have no args)' do
      entry = described_class.action_started_log_entry(
        token: 'tok-4', expires_at: expires_at,
        command: 'restart', scope: 'all',
        request_id: 'req-4', session_id_hash: 'sess-4',
        remote_ip: '127.0.0.1', user_agent: 'curl/8',
        route_kind: :typed_command
      )
      expect(entry[:args]).to be_nil
    end
  end

  describe '.action_confirmed_log_entry (v1.7.0+)' do
    it 'carries started_age_ms + the same redaction rule as _started' do
      entry = described_class.action_confirmed_log_entry(
        token: 'tok-1', command: 'restart', scope: 'all',
        request_id: 'req-1', session_id_hash: 'sess-1',
        remote_ip: '127.0.0.1', user_agent: 'browser', user: 'op',
        started_age_ms: 28_500
      )
      expect(entry).to include(
        event: 'admin.action_confirmed',
        confirmation_token: 'tok-1',
        started_age_ms: 28_500,
        request_id: 'req-1', user: 'op'
      )
    end
  end

  describe '.action_auto_confirmed_log_entry (v1.7.0+)' do
    it 'omits confirmation_token (no token was issued for the auto-confirm path)' do
      entry = described_class.action_auto_confirmed_log_entry(
        command: 'restart', scope: 'all',
        request_id: 'req-1', session_id_hash: 'sess-1',
        remote_ip: '127.0.0.1', user_agent: 'curl/8'
      )
      expect(entry).to include(event: 'admin.action_auto_confirmed', command: 'restart')
      expect(entry).not_to have_key(:confirmation_token)
    end
  end

  describe '.action_cancelled_log_entry (v1.7.0+)' do
    it 'carries the token + command/scope captured from the cancelled entry' do
      entry = described_class.action_cancelled_log_entry(
        token: 'tok-1', command: 'restart', scope: 'all',
        request_id: 'req-1', session_id_hash: 'sess-1', user: 'op'
      )
      expect(entry).to include(
        event: 'admin.action_cancelled',
        confirmation_token: 'tok-1',
        command: 'restart', scope: 'all'
      )
    end
  end

  describe '.action_rejected_log_entry (v1.7.0+) — single event with reason: discriminator' do
    it 'carries reason: :expired with the token + command + scope' do
      entry = described_class.action_rejected_log_entry(
        reason: :expired, token: 'tok-1',
        command: 'restart', scope: 'all',
        request_id: 'req-1', session_id_hash: 'sess-1', user: 'op'
      )
      expect(entry).to include(
        event: 'admin.action_rejected',
        reason: :expired,
        confirmation_token: 'tok-1',
        command: 'restart'
      )
    end

    it 'tolerates missing command/scope (reason: :not_found has no recoverable context)' do
      entry = described_class.action_rejected_log_entry(
        reason: :not_found, token: 'tok-x',
        request_id: 'req-1', session_id_hash: 'sess-1'
      )
      expect(entry).to include(
        event: 'admin.action_rejected',
        reason: :not_found,
        command: nil, scope: nil
      )
    end
  end

  describe '.redact_args' do
    it 'returns "[REDACTED: pool credentials]" for manage_pools/add' do
      out = described_class.redact_args(route_kind: :manage_pools, command: 'add', args: { url: 'x' })
      expect(out).to eq('[REDACTED: pool credentials]')
    end

    it 'passes through manage_pools/disable args (no credentials in args)' do
      out = described_class.redact_args(route_kind: :manage_pools, command: 'disable', args: '0')
      expect(out).to eq('0')
    end

    it 'passes through raw_run args' do
      out = described_class.redact_args(route_kind: :raw_run, command: 'pgaset', args: '0,clock,500')
      expect(out).to eq('0,clock,500')
    end

    it 'passes through typed_command args' do
      out = described_class.redact_args(route_kind: :typed_command, command: 'restart', args: nil)
      expect(out).to be_nil
    end
  end

  # Pins the count-map shape on both Fleet*Result types so the
  # `admin.result.failed_codes` field is consistent across query and
  # write commands. AdminLogging.result_log_entry duck-types over
  # whichever it gets at the call site.
  describe 'failed_codes_count_map shape via Fleet*Result' do
    let(:miner) { '127.0.0.1:4028' }
    let(:access_denied) { CgminerApiClient::AccessDeniedError.new('45: Access denied', cgminer_code: 45) }
    let(:timeout)       { CgminerApiClient::TimeoutError.new('connect timeout') }
    let(:conn_refused)  { CgminerApiClient::ConnectionError.new('refused') }

    context 'with a FleetWriteResult' do
      def write_entry(status:, error: nil)
        CgminerManager::FleetWriteEntry.new(miner: miner, status: status, response: nil, error: error)
      end

      it 'is empty when nothing failed' do
        result = CgminerManager::FleetWriteResult.new(entries: [write_entry(status: :ok)])
        expect(result.failed_codes_count_map).to eq({})
      end

      it 'aggregates a uniform fleet of access-denied failures' do
        entries = Array.new(3) { write_entry(status: :failed, error: access_denied) }
        result = CgminerManager::FleetWriteResult.new(entries: entries)
        expect(result.failed_codes_count_map).to eq({ access_denied: 3 })
      end

      it 'aggregates a mixed fleet across access_denied + connection_error + timeout' do
        entries = [
          write_entry(status: :failed, error: access_denied),
          write_entry(status: :failed, error: conn_refused),
          write_entry(status: :failed, error: timeout),
          write_entry(status: :ok)
        ]
        result = CgminerManager::FleetWriteResult.new(entries: entries)
        expect(result.failed_codes_count_map).to eq(access_denied: 1, connection_error: 1, timeout: 1)
      end
    end

    context 'with a FleetQueryResult' do
      def query_entry(passed:, error: nil)
        CgminerManager::FleetQueryEntry.new(miner: miner, ok: passed, response: nil, error: error)
      end

      it 'is empty when nothing failed' do
        result = CgminerManager::FleetQueryResult.new(entries: [query_entry(passed: true)])
        expect(result.failed_codes_count_map).to eq({})
      end

      it 'aggregates a uniform fleet of access-denied failures' do
        entries = Array.new(3) { query_entry(passed: false, error: access_denied) }
        result = CgminerManager::FleetQueryResult.new(entries: entries)
        expect(result.failed_codes_count_map).to eq({ access_denied: 3 })
      end
    end
  end
end
