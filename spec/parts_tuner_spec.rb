# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe Bi2zip::PartsTuner do
  # Walks PARTS_RANGE high to low so ties resolve to the largest parts, matching
  # the early-termination tuner.
  def brute_force_best(bytes, max_passes:)
    candidates = Bi2zip::Compress::PARTS_RANGE.to_a.reverse.map do |parts|
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

  it 'stops trialing once the cost regresses' do
    # 48 all-zero bytes: parts=15 produces a worse output than parts=16, so the
    # reverse walk bails after the second trial. The true global minimum lives
    # further down the range (parts=12), but the heuristic accepts that — that
    # is the deliberate trade for the speedup.
    bytes = Array.new(48, 0x00)
    trials = 0
    allow(Bi2zip::Compress).to receive(:call).and_wrap_original do |orig, **kwargs|
      trials += 1
      orig.call(**kwargs)
    end

    chosen = described_class.best(
      bytes: bytes, algorithms: Bi2zip::Algorithms::ALL,
      zlb: :auto, max_passes: :auto,
    )

    expect(chosen.parts).to eq(Bi2zip::Compress::PARTS_RANGE.max)
    expect(trials).to eq(2)
  end
end
