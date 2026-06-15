# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe Bi2zip::PartsTuner do
  def brute_force_best(bytes, max_passes:)
    candidates = Bi2zip::Compress::PARTS_RANGE.map do |parts|
      Bi2zip::Compress.call(bytes: bytes, parts: parts, max_passes: max_passes)
    end
    candidates.min_by { |r| r.bytes.bytesize }
  end

  it 'returns a Result whose parts matches the brute-force minimum' do
    bytes = Random.new(101).bytes(400).bytes
    expected = brute_force_best(bytes, max_passes: :auto)
    chosen = described_class.best(
      bytes: bytes, algorithms: Bi2zip::Algorithms::ALL,
      zlb: :auto, max_passes: :auto,
    )
    expect(chosen.bytes.bytesize).to eq(expected.bytes.bytesize)
    expect(chosen.parts).to eq(expected.parts)
  end

  it 'returns a Result whose parts is in the legal range' do
    bytes = Random.new(102).bytes(120).bytes
    chosen = described_class.best(
      bytes: bytes, algorithms: Bi2zip::Algorithms::ALL,
      zlb: :auto, max_passes: :auto,
    )
    expect(Bi2zip::Compress::PARTS_RANGE).to cover(chosen.parts)
  end
end
