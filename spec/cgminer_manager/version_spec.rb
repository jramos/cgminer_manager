# frozen_string_literal: true

RSpec.describe CgminerManager do
  describe 'VERSION' do
    it 'is a non-empty string' do
      expect(described_class::VERSION).to be_a(String)
      expect(described_class::VERSION).not_to be_empty
    end

    it 'follows semver-ish shape' do
      expect(described_class::VERSION).to match(/\A\d+\.\d+\.\d+(\.\w+)?\z/)
    end
  end
end
