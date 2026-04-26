# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CgminerManager::ConfirmationStore do
  subject(:store) { described_class.new(clock: -> { clock_now }) }

  let(:base_time) { Time.utc(2026, 4, 26, 12, 0, 0) }
  let(:session_a) { 'session-hash-a' }
  let(:session_b) { 'session-hash-b' }
  let(:clock_state) { { offset: 0 } }

  def clock_now
    base_time + clock_state[:offset]
  end

  def advance_clock(seconds)
    clock_state[:offset] += seconds
  end

  def make_entry(**overrides)
    defaults = {
      token: 'tok-1', command: 'restart', scope: 'all', args: nil,
      route_kind: :typed_command, request_id: 'req-1', user: 'op',
      session_id_hash: session_a,
      created_at: base_time, expires_at: base_time + 120
    }
    described_class::Entry.new(**defaults, **overrides)
  end

  describe '#put / #consume happy path' do
    it 'returns the entry verbatim on first consume with a matching session' do
      entry = make_entry
      store.put(entry)
      expect(store.consume('tok-1', session_a)).to eq(entry)
    end

    it 'returns :not_found on a second consume of the same token (single-use)' do
      store.put(make_entry)
      store.consume('tok-1', session_a)
      expect(store.consume('tok-1', session_a)).to eq(:not_found)
    end

    it 'returns :not_found for a token that was never put' do
      expect(store.consume('never-existed', session_a)).to eq(:not_found)
    end
  end

  describe '#consume session binding' do
    it 'returns :session_mismatch when the confirming session differs and leaves the entry intact' do
      store.put(make_entry)
      expect(store.consume('tok-1', session_b)).to eq(:session_mismatch)
      # Original session can still consume — entry was NOT removed by the mismatch.
      expect(store.consume('tok-1', session_a).token).to eq('tok-1')
    end
  end

  describe '#consume expiry' do
    it 'returns :expired and removes the entry when expires_at is in the past' do
      store.put(make_entry(expires_at: base_time - 1))
      expect(store.consume('tok-1', session_a)).to eq(:expired)
      # Entry is gone — second consume sees :not_found.
      expect(store.consume('tok-1', session_a)).to eq(:not_found)
    end

    it 'reports :session_mismatch ahead of :expired when both apply (session check is the protective gate)' do
      store.put(make_entry(expires_at: base_time - 1))
      expect(store.consume('tok-1', session_b)).to eq(:session_mismatch)
    end
  end

  describe '#peek' do
    it 'returns the entry without consuming it' do
      store.put(make_entry)
      peeked = store.peek('tok-1')
      expect(peeked.token).to eq('tok-1')
      expect(store.consume('tok-1', session_a)).to eq(peeked)
    end

    it 'returns nil for an unknown token' do
      expect(store.peek('nope')).to be_nil
    end

    it 'returns the entry even when expired (peek does not enforce expiry — caller decides)' do
      store.put(make_entry(expires_at: base_time - 1))
      expect(store.peek('tok-1')).not_to be_nil
    end

    it 'peek-then-token-expires-before-consume still rejects with :expired (no race)' do
      store.put(make_entry(expires_at: base_time + 1))
      store.peek('tok-1')
      advance_clock(2)
      expect(store.consume('tok-1', session_a)).to eq(:expired)
    end
  end

  describe '#cancel' do
    it 'returns the entry, removes it, and subsequent consume returns :not_found' do
      entry = make_entry
      store.put(entry)
      expect(store.cancel('tok-1', session_a)).to eq(entry)
      expect(store.consume('tok-1', session_a)).to eq(:not_found)
    end

    it 'returns :session_mismatch and leaves the entry when the cancelling session differs' do
      store.put(make_entry)
      expect(store.cancel('tok-1', session_b)).to eq(:session_mismatch)
      expect(store.consume('tok-1', session_a).token).to eq('tok-1')
    end

    it 'returns :not_found for a token that was never put' do
      expect(store.cancel('nope', session_a)).to eq(:not_found)
    end
  end

  describe '#put MAX_PENDING eviction' do
    it 'evicts the oldest entry by created_at when the cap is exceeded and returns the evicted entry' do
      stub_const("#{described_class}::MAX_PENDING", 3)

      store.put(make_entry(token: 't1', created_at: base_time))
      store.put(make_entry(token: 't2', created_at: base_time + 1))
      store.put(make_entry(token: 't3', created_at: base_time + 2))
      evicted = store.put(make_entry(token: 't4', created_at: base_time + 3))

      expect(evicted&.token).to eq('t1')
      expect(store.peek('t1')).to be_nil
      expect(store.peek('t4')).not_to be_nil
    end

    it 'returns nil from #put when no eviction was needed' do
      stub_const("#{described_class}::MAX_PENDING", 3)
      expect(store.put(make_entry(token: 't1'))).to be_nil
    end
  end

  describe '#purge_expired!' do
    it 'returns the array of expired Entries removed and leaves live entries in place' do
      store.put(make_entry(token: 't-live', expires_at: base_time + 60))
      store.put(make_entry(token: 't-stale-1', expires_at: base_time - 1))
      store.put(make_entry(token: 't-stale-2', expires_at: base_time - 5))

      purged = store.purge_expired!
      tokens = purged.map(&:token)
      expect(tokens).to contain_exactly('t-stale-1', 't-stale-2')
      expect(store.peek('t-live')).not_to be_nil
      expect(store.peek('t-stale-1')).to be_nil
    end
  end

  describe 'thread safety' do
    it 'lets only one of two racing consumes succeed (single-use under contention)' do
      store.put(make_entry)
      results = []
      mutex   = Mutex.new

      threads = Array.new(2) do
        Thread.new do
          r = store.consume('tok-1', session_a)
          mutex.synchronize { results << r }
        end
      end
      threads.each(&:join)

      expect(results.count { |r| r.is_a?(described_class::Entry) }).to eq(1)
      expect(results.count { |r| r == :not_found }).to eq(1)
    end
  end

  describe 'double-click idempotency (decision #15)' do
    it 'lets the same operator put two entries for the same (command, scope) and confirms either independently' do
      store.put(make_entry(token: 'click-1'))
      store.put(make_entry(token: 'click-2'))
      expect(store.consume('click-1', session_a).token).to eq('click-1')
      expect(store.consume('click-2', session_a).token).to eq('click-2')
    end
  end
end
