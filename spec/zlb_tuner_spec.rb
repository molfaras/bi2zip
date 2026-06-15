# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe Bi2zip::ZlbTuner do
  def brute_force_best(raw)
    candidates = described_class::ZLB_RANGE.map do |zlb|
      [zlb, Bi2zip::RLE.encode(raw, zero_len_bits: zlb)]
    end
    min_len = candidates.map { |_, enc| enc.length }.min
    candidates.find { |_, enc| enc.length == min_len }
  end

  inputs = {
    'all ones' => '1' * 50,
    'single zero' => '0',
    'long zero run' => '0' * 4096,
    'mixed short runs' => ('1' * 3 + '0' * 5 + '1' * 7 + '0' * 11) * 4,
    'alternating bits' => '01' * 64,
  }

  inputs.each do |label, raw|
    it "matches brute force for #{label}" do
      expected_zlb, expected_encoded = brute_force_best(raw)
      zlb, encoded = described_class.best(raw)
      expect(zlb).to eq(expected_zlb)
      expect(encoded).to eq(expected_encoded)
    end
  end

  it 'returns the minimum zlb and empty encoded for empty input' do
    zlb, encoded = described_class.best('')
    expect(zlb).to eq(described_class::ZLB_RANGE.min)
    expect(encoded).to eq('')
  end
end
