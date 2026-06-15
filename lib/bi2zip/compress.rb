# frozen_string_literal: true

require_relative 'algorithms'
require_relative 'rle'
require_relative 'varint'
require_relative 'zlb_tuner'

module Bi2zip
  # Multi-pass bit-level compressor.
  #
  # The input is sliced into chunks of PARTS bytes. Byte j of each chunk goes
  # into stripe j, so each stripe is a bit-string of length 8 * num_full_chunks.
  # A trailing partial chunk (< PARTS bytes) is preserved verbatim as leftover.
  #
  # Each pass picks one Bi2zip::Algorithms transform and walks neighbouring columns
  # across the stripes. When forward(name, column(i)) == column(i + 1), the
  # left column is dropped and the rule stream emits a '1'; otherwise the
  # column is kept and a '0' is emitted. The per-pass raw rules are then
  # RLE-encoded with the zlb that yields the shortest output.
  #
  # The first pass is forced to :eq (the only no-cost choice). Subsequent
  # passes are chosen by pre-scanning every algorithm on a clone of the
  # current stripes and picking the one with the most matches. Ties fall to
  # the declaration order in Bi2zip::Algorithms::ALL.
  class Compress
    PARTS_RANGE = (4..16).freeze
    ZLB_RANGE = (4..16).freeze
    MAX_PASSES_RANGE = (1..10).freeze

    Pass = Data.define(:name, :raw_rules, :encoded_rules, :zlb, :matches)

    Result = Data.define(
      :parts, :original_byte_count, :passes, :bytes, :stats,
    )

    def self.call(bytes:, parts: 12, algorithms: Algorithms::ALL,
                  zlb: :auto, max_passes: :auto)
      new(
        bytes: bytes, parts: parts, algorithms: algorithms,
        zlb: zlb, max_passes: max_passes,
      ).call
    end

    def initialize(bytes:, parts:, algorithms:, zlb:, max_passes:)
      validate_parts!(parts)
      validate_algorithms!(algorithms)
      validate_zlb!(zlb)
      validate_max_passes!(max_passes)

      @parts = parts
      @algorithms = algorithms
      @zlb_setting = zlb
      @max_passes = max_passes
      @bytes = bytes
      @original_byte_count = bytes.length
    end

    def call
      build_stripes
      tuned = @max_passes == :auto ? run_pipeline_auto : run_pipeline.map { |p| tune_pass(p) }
      Result.new(
        parts: @parts,
        original_byte_count: @original_byte_count,
        passes: tuned,
        bytes: build_stream(tuned),
        stats: build_stats(tuned),
      )
    end

    private

    def validate_parts!(parts)
      return if parts == :auto
      return if parts.is_a?(Integer) && PARTS_RANGE.include?(parts)

      raise ArgumentError,
            "parts must be :auto or an integer in #{PARTS_RANGE} (got #{parts.inspect})"
    end

    def validate_algorithms!(algorithms)
      unless algorithms.is_a?(Array) && !algorithms.empty?
        raise ArgumentError, "algorithms must be a non-empty array (got #{algorithms.inspect})"
      end

      bad = algorithms.reject { |name| Algorithms::ALL.include?(name) }
      return if bad.empty?

      raise ArgumentError,
            "unknown algorithms: #{bad.inspect} (known: #{Algorithms::ALL.inspect})"
    end

    def validate_zlb!(zlb)
      return if zlb == :auto
      return if zlb.is_a?(Integer) && ZLB_RANGE.include?(zlb)

      raise ArgumentError, "zlb must be :auto or an integer in #{ZLB_RANGE} (got #{zlb.inspect})"
    end

    def validate_max_passes!(max_passes)
      return if max_passes == :auto
      return if max_passes.is_a?(Integer) && MAX_PASSES_RANGE.include?(max_passes)

      raise ArgumentError,
            "max_passes must be :auto or an integer in #{MAX_PASSES_RANGE} (got #{max_passes.inspect})"
    end

    def build_stripes
      @stripes = Array.new(@parts) { +'' }
      @leftover_bytes = []
      @bytes.each_slice(@parts) do |chunk|
        if chunk.size == @parts
          @parts.times { |j| @stripes[j] << format('%08b', chunk[j]) }
        else
          @leftover_bytes = chunk
        end
      end
    end

    def run_pipeline
      passes = []
      first = run_pass(:eq)
      passes << first if first.matches.positive?

      until passes.size >= @max_passes
        name, matches = pick_next_algorithm
        break if matches.zero?

        passes << run_pass(name)
      end

      passes
    end

    # Greedy pass loop with a 1-step lookahead: keep a pass only while its
    # rules cost is offset by the reduction in stripe bytes it produces.
    # When a pass would grow the total, undo it and stop. The first :eq pass
    # is silently skipped when it produces no matches so that later passes
    # (e.g. :inv) can still fire, matching the integer-cap behaviour. The
    # seed :eq pass bypasses the cost gate on the same grounds: keeping it
    # unconditionally preserves the integer-cap shape (run_pipeline does the
    # same) and the global abort-on-expansion in the CLI is the real backstop.
    def run_pipeline_auto
      kept = []
      first = run_pass(:eq)
      kept << tune_pass(first) if first.matches.positive?

      until kept.size >= MAX_PASSES_RANGE.max
        name, matches = pick_next_algorithm
        break if matches.zero?

        snapshot = @stripes.map(&:dup)
        cost_before = stripes_stream_cost
        candidate = tune_pass(run_pass(name))
        cost_after = stripes_stream_cost + pass_chunk(candidate).bytesize

        if cost_after <= cost_before
          kept << candidate
        else
          @stripes = snapshot
          break
        end
      end
      kept
    end

    def pick_next_algorithm
      best_name = nil
      best_matches = 0
      @algorithms.each do |name|
        matches = prescan(name)
        if matches > best_matches
          best_matches = matches
          best_name = name
        end
      end
      [best_name, best_matches]
    end

    def prescan(name)
      walk_pass(@stripes.map(&:dup), name, record: false)
    end

    def run_pass(name)
      matches, raw = walk_pass(@stripes, name, record: true)
      Pass.new(name: name, raw_rules: raw, encoded_rules: nil, zlb: nil, matches: matches)
    end

    def walk_pass(stripes, name, record:)
      raw = (+'' if record)
      matches = 0
      i = 0
      stripe_len = stripes.first&.length || 0
      while i < stripe_len - 1
        left = column_of(stripes, i)
        right = column_of(stripes, i + 1)
        if Algorithms.forward(name, left) == right
          raw << '1' if record
          slice_column!(stripes, i)
          stripe_len -= 1
          matches += 1
        elsif record
          raw << '0'
        end
        i += 1
      end
      record ? [matches, raw] : matches
    end

    def column_of(stripes, index)
      buf = +''
      @parts.times { |j| buf << stripes[j][index] }
      buf
    end

    def slice_column!(stripes, index)
      @parts.times { |j| stripes[j].slice!(index, 1) }
    end

    def tune_pass(pass)
      if @zlb_setting == :auto
        zlb, encoded = ZlbTuner.best(pass.raw_rules)
      else
        zlb = @zlb_setting
        encoded = RLE.encode(pass.raw_rules, zero_len_bits: zlb)
      end
      Pass.new(
        name: pass.name, raw_rules: pass.raw_rules,
        encoded_rules: encoded, zlb: zlb, matches: pass.matches,
      )
    end

    def stripe_bit_length
      @stripes.first&.length || 0
    end

    def stripes_block_size
      @parts * ((stripe_bit_length + 7) / 8)
    end

    # The portion of the stream cost that varies with stripe length:
    # the varint-encoded stripe_bit_length plus the packed stripe bytes.
    # Used by the auto-pipeline cost gate so it sees real byte deltas.
    def stripes_stream_cost
      Varint.encode(stripe_bit_length).bytesize + stripes_block_size
    end

    def build_stream(passes)
      header = [(@parts - 4) << 4].pack('C') +
               Varint.encode(@original_byte_count) +
               Varint.encode(stripe_bit_length)
      stripe_chunk = @stripes.map { |s| pack_bits(s) }.join
      leftover_chunk = @leftover_bytes.pack('C*')
      header + stripe_chunk + leftover_chunk + passes.map { |p| pass_chunk(p) }.join
    end

    def pass_chunk(pass)
      config = (Algorithms::ID.fetch(pass.name) << 4) | (pass.zlb - 4)
      [config].pack('C') +
        Varint.encode(pass.encoded_rules.length) +
        pack_bits(pass.encoded_rules)
    end

    def build_stats(passes)
      total_matches = passes.sum(&:matches)
      per_pass = passes.map do |pass|
        {
          name: pass.name,
          matches: pass.matches,
          zlb: pass.zlb,
          encoded_bits: pass.encoded_rules.length,
        }
      end
      { passes: passes.size, total_matches: total_matches, per_pass: per_pass }
    end

    def pack_bits(bit_string)
      return ''.b if bit_string.nil? || bit_string.empty?

      padded = bit_string.ljust(((bit_string.length + 7) / 8) * 8, '0')
      [padded].pack('B*')
    end
  end
end
