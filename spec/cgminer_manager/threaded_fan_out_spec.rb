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

    it 'caps concurrency at thread_cap (peak live workers never exceeds cap)' do
      live = 0
      peak = 0
      mutex = Mutex.new
      items = Array.new(10) { |i| i }
      described_class.map(items, thread_cap: 3) do |i|
        mutex.synchronize do
          live += 1
          peak = live if live > peak
        end
        sleep 0.02
        mutex.synchronize { live -= 1 }
        i
      end
      expect(peak).to eq(3)
    end

    it 'raises ArgumentError when thread_cap is nil (fail loud on misconfiguration)' do
      expect { described_class.map([1, 2, 3], thread_cap: nil) { |n| n } }
        .to raise_error(ArgumentError, /thread_cap/)
    end

    it 'clamps sub-1 caps to 1' do
      expect(described_class.map([1, 2, 3], thread_cap: 0) { |n| n }).to eq([1, 2, 3])
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
  end
end
