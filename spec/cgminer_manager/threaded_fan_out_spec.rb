# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CgminerManager::ThreadedFanOut do
  describe '.map' do
    it 'returns an ordered array of block results matching input order' do
      out = described_class.map([1, 2, 3, 4, 5], thread_cap: 2) { |n| n * 10 }
      expect(out).to eq([10, 20, 30, 40, 50])
    end

    it 'preserves input order regardless of completion order (slow middle item)' do
      out = described_class.map([0.01, 0.05, 0.01], thread_cap: 3) do |delay|
        sleep(delay)
        delay
      end
      expect(out).to eq([0.01, 0.05, 0.01])
    end

    it 'preserves ordering when items are ==-equal (pair-enqueue regression guard)' do
      # Without (index, item) pair enqueue, an internal `item => index`
      # hash would collapse duplicates and the second :a result would
      # overwrite the first.
      out = described_class.map(%i[a b a], thread_cap: 2) { |sym| sym.to_s.upcase }
      expect(out).to eq(%w[A B A])
    end

    it 'caps concurrency at thread_cap (peak never exceeds cap)' do
      live = 0
      peak = 0
      mutex = Mutex.new
      items = Array.new(20) { |i| i }
      described_class.map(items, thread_cap: 3) do |i|
        mutex.synchronize do
          live += 1
          peak = live if live > peak
        end
        sleep 0.02
        mutex.synchronize { live -= 1 }
        i
      end
      expect(peak).to be <= 3
      expect(peak).to be >= 2 # evidence of real parallelism
    end

    it 'raises ArgumentError when thread_cap is nil (fail loud on misconfiguration)' do
      expect { described_class.map([1, 2, 3], thread_cap: nil) { |n| n } }
        .to raise_error(ArgumentError, /thread_cap/)
    end

    it 'raises ArgumentError when called without a block' do
      expect { described_class.map([1, 2, 3], thread_cap: 2) }
        .to raise_error(ArgumentError, /block/)
    end

    it 'clamps thread_cap: 0 to 1 worker' do
      expect(described_class.map([1, 2, 3], thread_cap: 0) { |n| n }).to eq([1, 2, 3])
    end

    it 'clamps negative thread_cap to 1 worker' do
      expect(described_class.map([1, 2, 3], thread_cap: -5) { |n| n }).to eq([1, 2, 3])
    end

    it 'returns an empty array for empty items without invoking the block' do
      block_invocations = 0
      result = described_class.map([], thread_cap: 4) { |_| block_invocations += 1 }
      expect(result).to eq([])
      expect(block_invocations).to eq(0)
    end

    it 'propagates unhandled exceptions from the block (fail loud)' do
      expect do
        described_class.map([1, 2, 3], thread_cap: 2) { |n| raise 'boom' if n == 2 }
      end.to raise_error(RuntimeError, /boom/)
    end

    it 'aborts remaining work after the first block exception (siblings do not keep firing)' do
      # Without abort-on-failure, all 50 items would be processed even
      # though item 2 raises — side effects from workers draining the
      # queue in the background would outlive the caller's rescue.
      processed = 0
      mutex = Mutex.new
      items = (1..50).to_a
      expect do
        described_class.map(items, thread_cap: 2) do |i|
          mutex.synchronize { processed += 1 }
          raise 'boom' if i == 2

          sleep 0.005
        end
      end.to raise_error(RuntimeError, /boom/)
      expect(processed).to be < items.size
    end
  end
end
