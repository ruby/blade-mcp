# frozen_string_literal: true

module BladeMcp
  # Heroku Postgres offers neither pg_bigm nor PGroonga, so Japanese text is
  # split into overlapping two-character tokens before it reaches the
  # `simple` parser, and queries are split the same way and joined with <->.
  module Bigram
    RUN = /[\p{Han}\p{Hiragana}\p{Katakana}ー]+/

    module_function

    def expand(text)
      text.to_s.gsub(RUN) do |run|
        tokens = run.size == 1 ? [run] : run.each_char.each_cons(2).map(&:join)
        " #{tokens.join(' ')} "
      end
    end

    def words(query)
      query.to_s.scan(/"([^"]+)"|(\S+)/).map { |quoted, word| quoted || word }
    end

    def phrases(query)
      words(query).filter_map do |word|
        phrase = expand(word).split.join(' ')
        phrase if phrase.match?(/[\p{L}\p{N}]/)
      end
    end
  end
end
