# frozen_string_literal: true

RSpec.describe CgminerManager::ViewMiner do
  describe '.build' do
    it 'yields .host, .port (Integer), .available?, and .to_s' do
      vm = described_class.build('h', 4028, true)
      expect(vm.host).to eq('h')
      expect(vm.port).to eq(4028)
      expect(vm.port).to be_a(Integer)
      expect(vm.available?).to be(true)
      expect(vm.to_s).to eq('h:4028')
    end

    it 'coerces string ports to Integer' do
      vm = described_class.build('h', '4028', true)
      expect(vm.port).to eq(4028)
      expect(vm.port).to be_a(Integer)
    end

    it 'supports value equality (needed by uniq!)' do
      a = described_class.build('h', 4028, true)
      b = described_class.build('h', 4028, true)
      expect(a).to eq(b)
      expect([a, b].uniq.size).to eq(1)
    end

    it 'defaults label to nil and to_s falls back to host:port' do
      vm = described_class.build('127.0.0.1', 40_281, true)
      expect(vm.label).to be_nil
      expect(vm.display_label).to eq('127.0.0.1:40281')
      expect(vm.to_s).to eq('127.0.0.1:40281')
    end

    it 'uses the label for display when provided (routing still uses host:port)' do
      vm = described_class.build('127.0.0.1', 40_281, true, '192.168.1.151:4028')
      expect(vm.host_port).to eq('127.0.0.1:40281')
      expect(vm.display_label).to eq('192.168.1.151:4028')
      expect(vm.to_s).to eq('192.168.1.151:4028')
    end

    it 'treats empty-string label as nil' do
      vm = described_class.build('127.0.0.1', 40_281, true, '')
      expect(vm.label).to be_nil
    end
  end
end

RSpec.describe CgminerManager::ViewMinerPool do
  let(:available)   { CgminerManager::ViewMiner.build('up',   4028, true) }
  let(:unavailable) { CgminerManager::ViewMiner.build('down', 4028, false) }

  it 'partitions into available_miners / unavailable_miners' do
    pool = described_class.new(miners: [available, unavailable])
    expect(pool.available_miners).to eq([available])
    expect(pool.unavailable_miners).to eq([unavailable])
  end
end
