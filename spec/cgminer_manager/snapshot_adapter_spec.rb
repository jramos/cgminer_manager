# frozen_string_literal: true

RSpec.describe CgminerManager::SnapshotAdapter do
  describe '.sanitize' do
    it 'downcases keys and replaces spaces with underscores' do
      input = { 'MHS 5s' => 5.1, 'Temperature' => 62.0 }
      expect(described_class.sanitize(input)).to eq(mhs_5s: 5.1, temperature: 62.0)
    end

    it 'preserves % literal in keys (does NOT convert to _pct)' do
      input = { 'Device Hardware%' => 0.01 }
      expect(described_class.sanitize(input)).to eq('device_hardware%': 0.01)
    end

    it 'walks nested arrays and hashes' do
      input = {
        'SUMMARY' => [
          { 'MHS 5s' => 5.1, 'Device Hardware%' => 0.01 },
          { 'Temperature' => 62.0 }
        ]
      }
      expect(described_class.sanitize(input)).to eq(
        summary: [
          { mhs_5s: 5.1, 'device_hardware%': 0.01 },
          { temperature: 62.0 }
        ]
      )
    end

    it 'handles symbol keys via to_s coercion' do
      expect(described_class.sanitize('MHS 5s': 5.1)).to eq(mhs_5s: 5.1)
    end
  end

  describe '.legacy_shape' do
    it 'returns nil for nil snapshot' do
      expect(described_class.legacy_shape(nil, :summary)).to be_nil
    end

    it 'returns nil when snapshot has :error key' do
      expect(described_class.legacy_shape({ error: 'boom' }, :summary)).to be_nil
    end

    it 'returns nil when :response is nil' do
      expect(described_class.legacy_shape({ response: nil }, :summary)).to be_nil
    end

    it 'wraps a valid response in the legacy [{ type => [sanitized_hash] }] shape' do
      snapshot = {
        response: { 'SUMMARY' => [{ 'MHS 5s' => 5.1 }] },
        ok: true,
        fetched_at: '2026-04-16T00:00:00Z'
      }
      expect(described_class.legacy_shape(snapshot, :summary)).to eq(
        [{ summary: [{ mhs_5s: 5.1 }] }]
      )
    end

    it 'falls back to [] when the inner type key is missing' do
      snapshot = { response: { 'OTHER' => [] } }
      expect(described_class.legacy_shape(snapshot, :summary)).to eq([{ summary: [] }])
    end
  end

  describe '.build_miner_data' do
    it 'maps configured miners to keyed sub-snapshots' do
      configured = [['10.0.0.1', 4028]]
      tile = {
        summary: { response: { 'SUMMARY' => [{ 'MHS 5s' => 5.1 }] } },
        devices: { response: { 'DEVS' => [{ 'Temperature' => 62.0 }] } },
        pools: { response: { 'POOLS' => [{ 'URL' => 'p' }] } },
        stats: { response: { 'STATS' => [{ 'ID' => 'AVA10' }] } }
      }
      result = described_class.build_miner_data(configured, { '10.0.0.1:4028' => tile })
      expect(result).to eq(
        [{
          summary: [{ summary: [{ mhs_5s: 5.1 }] }],
          devs: [{ devs: [{ temperature: 62.0 }] }],
          pools: [{ pools: [{ url: 'p' }] }],
          stats: [{ stats: [{ id: 'AVA10' }] }]
        }]
      )
    end

    it 'yields all-nil sub-snapshots when the tile is missing' do
      configured = [['10.0.0.1', 4028]]
      result = described_class.build_miner_data(configured, {})
      expect(result).to eq([{ summary: nil, devs: nil, pools: nil, stats: nil }])
    end
  end
end
