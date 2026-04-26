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

  describe '.code_for' do
    it 'returns ApiError#code Symbol verbatim (covers AccessDeniedError subclass too)' do
      err = CgminerApiClient::AccessDeniedError.new('45: Access denied', cgminer_code: 45)
      expect(described_class.code_for(err)).to eq(:access_denied)
    end

    it 'maps a base ApiError with cgminer_code: 45 to :access_denied via api_client' do
      err = CgminerApiClient::ApiError.new('45: Access denied', cgminer_code: 45)
      expect(described_class.code_for(err)).to eq(:access_denied)
    end

    it 'synthesizes :timeout for CgminerApiClient::TimeoutError (no wire code available)' do
      expect(described_class.code_for(CgminerApiClient::TimeoutError.new('connect timeout')))
        .to eq(:timeout)
    end

    it 'synthesizes :connection_error for CgminerApiClient::ConnectionError' do
      expect(described_class.code_for(CgminerApiClient::ConnectionError.new('refused')))
        .to eq(:connection_error)
    end

    it 'falls through to :unexpected for any non-CgminerApiClient StandardError' do
      expect(described_class.code_for(StandardError.new('out of left field')))
        .to eq(:unexpected)
    end

    it 'guards against duck-typed #code methods that do not return a Symbol' do
      stray = Struct.new(:code).new(500) # mimics e.g. an HTTP-status-bearing object
      expect(described_class.code_for(stray)).to eq(:unexpected)
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
