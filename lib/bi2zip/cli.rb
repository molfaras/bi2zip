# frozen_string_literal: true

require 'optparse'

require_relative '../bi2zip'

module Bi2zip
  # Command-line entry point. Mode is inferred from the input path: anything
  # ending in `.bi2zip` is decompressed; everything else is compressed.
  class CLI
    EXIT_OK = 0
    EXIT_USAGE = 1
    EXIT_INPUT = 2

    PROGRAM_NAME = 'bin/bi2zip'
    DATA_EXTENSION = '.bi2zip'

    def self.run(argv, stdout: $stdout, stderr: $stderr)
      new(argv, stdout: stdout, stderr: stderr).run
    end

    def initialize(argv, stdout: $stdout, stderr: $stderr)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
    end

    def run
      return handle_top_level_flag(@argv.first) if top_level_flag?(@argv.first)
      return usage_error('missing input path') if @argv.empty?

      if @argv.any? { |a| a.end_with?(DATA_EXTENSION) }
        DecompressCommand.new(@argv, stdout: @stdout, stderr: @stderr).run
      else
        CompressCommand.new(@argv, stdout: @stdout, stderr: @stderr).run
      end
    end

    private

    def top_level_flag?(arg)
      %w[-h --help --version].include?(arg)
    end

    def handle_top_level_flag(flag)
      if flag == '--version'
        @stdout.puts "bi2zip #{Bi2zip::VERSION}"
      else
        @stdout.puts CLI.help_text
      end
      EXIT_OK
    end

    def usage_error(message)
      @stderr.puts message
      @stderr.puts CLI.usage_hint
      EXIT_USAGE
    end

    def self.usage_hint
      "Usage: #{PROGRAM_NAME} [options] <input>\n" \
        "       #{PROGRAM_NAME} <input.bi2zip> [<output>]\n" \
        "Run `#{PROGRAM_NAME} --help` for details."
    end

    def self.help_text
      <<~HELP
        Usage: #{PROGRAM_NAME} [options] <input>           # compress
               #{PROGRAM_NAME} <input.bi2zip> [<output>]   # decompress

        Mode is chosen by extension: paths ending in `.bi2zip` are decompressed,
        anything else is compressed. When decompressing without an explicit
        <output>, writes to the original filename (input minus `.bi2zip`),
        picking the next free ` (N)` variant if that path already exists.

        Compress options:
          --parts VALUE        Bytes per chunk (4..16) or "auto" (default).
          --algorithms LIST    Comma-separated subset of: eq,inv,lshift,rshift,lgray,rgray.
          --zlb VALUE          Zero-run length bits (4..16) or "auto" (default).
          --max-passes VALUE   Maximum number of passes (1..10) or "auto" (default).

        Top-level options:
          -h, --help           Print this help and exit.
              --version        Print version and exit.

        Exit codes:
          0  success
          1  usage error (bad arguments)
          2  input error (missing file, malformed header, validation failure)
      HELP
    end

    # Shared scaffolding for both modes.
    class Subcommand
      def initialize(argv, stdout:, stderr:)
        @argv = argv.dup
        @stdout = stdout
        @stderr = stderr
      end

      protected

      def usage_error(message)
        @stderr.puts message
        @stderr.puts subcommand_usage_hint
        CLI::EXIT_USAGE
      end

      def input_error(message)
        @stderr.puts message
        CLI::EXIT_INPUT
      end
    end

    class CompressCommand < Subcommand
      def run
        parts = :auto
        algorithms = Bi2zip::Algorithms::ALL.dup
        zlb = :auto
        max_passes = :auto
        show_help = false

        parser = OptionParser.new do |opts|
          opts.banner = "Usage: #{PROGRAM_NAME} [--parts N|auto] [--algorithms a,b,c] " \
                        '[--zlb N|auto] [--max-passes N|auto] <input>'
          opts.on('--parts VALUE', 'Bytes per chunk (4..16) or "auto" (default).') do |v|
            parts = parse_int_or_auto(v)
          end
          opts.on('--algorithms LIST', Array,
                  "Comma-separated subset of: #{Bi2zip::Algorithms::ALL.join(',')}.") do |v|
            algorithms = v.map(&:to_sym)
          end
          opts.on('--zlb VALUE', 'Zero-run length bits (4..16) or "auto" (default).') do |v|
            zlb = parse_int_or_auto(v)
          end
          opts.on('--max-passes VALUE', 'Maximum number of passes (1..10) or "auto" (default).') do |v|
            max_passes = parse_int_or_auto(v)
          end
          opts.on('-h', '--help', 'Print this help and exit.') { show_help = true }
        end

        positional = parser.parse(@argv)
        if show_help
          @stdout.puts parser.help
          return CLI::EXIT_OK
        end
        return usage_error('expected exactly one input path') unless positional.length == 1

        compress(
          positional[0],
          parts: parts, algorithms: algorithms, zlb: zlb, max_passes: max_passes,
        )
      rescue OptionParser::ParseError => e
        usage_error(e.message)
      rescue ArgumentError => e
        input_error(e.message)
      end

      private

      def compress(path, parts:, algorithms:, zlb:, max_passes:)
        return input_error("no such file: #{path}") unless File.file?(path)

        raw = File.binread(path)
        result = Bi2zip::Compress.call(
          bytes: raw.bytes,
          parts: parts,
          algorithms: algorithms,
          zlb: zlb,
          max_passes: max_passes,
        )

        if result.bytes.bytesize >= raw.bytesize
          @stderr.puts "aborting: compressed size #{result.bytes.bytesize} B " \
                       "would not shrink #{raw.bytesize} B input"
          return CLI::EXIT_OK
        end

        data_path = "#{path}#{CLI::DATA_EXTENSION}"
        File.binwrite(data_path, result.bytes)
        report(data_path, result, raw.bytesize)
        CLI::EXIT_OK
      rescue ArgumentError => e
        input_error(e.message)
      end

      def report(data_path, result, original_byte_count)
        ratio = original_byte_count.zero? ? 0.0 : result.bytes.bytesize.to_f / original_byte_count
        @stdout.puts "wrote #{data_path}"
        @stdout.puts format(
          'passes=%<passes>d matches=%<matches>d ratio=%<ratio>.3f',
          passes: result.stats[:passes],
          matches: result.stats[:total_matches],
          ratio: ratio,
        )
        result.stats[:per_pass].each_with_index do |entry, index|
          @stdout.puts format(
            '[%<n>d] name=%<name>s zlb=%<zlb>d matches=%<matches>d bits=%<bits>d',
            n: index + 1, name: entry[:name], zlb: entry[:zlb],
            matches: entry[:matches], bits: entry[:encoded_bits],
          )
        end
      end

      def subcommand_usage_hint
        "Usage: #{PROGRAM_NAME} [--parts N|auto] [--algorithms a,b,c] " \
          '[--zlb N|auto] [--max-passes N|auto] <input>'
      end

      def parse_int_or_auto(value)
        return :auto if value == 'auto'

        parsed = Integer(value, exception: false)
        raise OptionParser::InvalidArgument, value if parsed.nil?

        parsed
      end
    end

    class DecompressCommand < Subcommand
      def run
        show_help = false
        parser = OptionParser.new do |opts|
          opts.banner = "Usage: #{PROGRAM_NAME} <input.bi2zip> [<output>]"
          opts.on('-h', '--help', 'Print this help and exit.') { show_help = true }
        end

        positional = parser.parse(@argv)
        if show_help
          @stdout.puts parser.help
          return CLI::EXIT_OK
        end
        unless (1..2).cover?(positional.length)
          return usage_error('expected <input.bi2zip> [<output>]')
        end

        decompress(*positional)
      rescue OptionParser::ParseError => e
        usage_error(e.message)
      end

      private

      def decompress(input, output_path = nil)
        return input_error("no such file: #{input}") unless File.file?(input)

        output_path ||= resolve_default_output(input)
        if File.expand_path(output_path) == File.expand_path(input)
          return input_error("refusing to overwrite input file: #{output_path}")
        end

        restored = Bi2zip::Decompress.from_path(path: input)
        File.binwrite(output_path, restored)
        @stdout.puts output_path
        CLI::EXIT_OK
      rescue ArgumentError => e
        input_error(e.message)
      end

      MAX_CONFLICT_SUFFIX = 9999

      # Finder-style ` (N)` conflict resolution: suffix lands before the last
      # extension when there is one, otherwise at the end of the basename.
      def resolve_default_output(input)
        base = input.delete_suffix(CLI::DATA_EXTENSION)
        if base.empty? || base.end_with?('/')
          raise ArgumentError, "input path has no name before #{CLI::DATA_EXTENSION}"
        end

        return base unless File.exist?(base)

        (1..MAX_CONFLICT_SUFFIX).each do |n|
          candidate = with_conflict_suffix(base, n)
          return candidate unless File.exist?(candidate)
        end
        raise ArgumentError,
              "no available output filename for #{base} (tried up to N=#{MAX_CONFLICT_SUFFIX})"
      end

      def with_conflict_suffix(path, suffix)
        dir = File.dirname(path)
        name = File.basename(path)
        ext = File.extname(name)
        stem = ext.empty? ? name : name[0...-ext.length]
        suffixed = "#{stem} (#{suffix})#{ext}"
        # Preserve a bare filename (no directory) instead of inserting "./".
        dir == '.' && !path.start_with?('./') ? suffixed : File.join(dir, suffixed)
      end

      def subcommand_usage_hint
        "Usage: #{PROGRAM_NAME} <input.bi2zip> [<output>]"
      end
    end
  end
end
