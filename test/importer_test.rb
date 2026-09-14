# frozen_string_literal: true

require 'test_helper'

class ImporterTest < BladeMcp::TestCase
  class FakeVault
    def initialize(messages)
      @messages = messages
    end

    def seqs(list)
      @messages.keys.filter_map { |key_list, seq| seq if key_list == list }.sort
    end

    def fetch(list, seq)
      message = @messages.fetch([list, seq])
      raise message if message.is_a?(Exception)
      message
    end
  end

  def run_importer(vault, lists = %w[ruby-dev], **options)
    log = StringIO.new
    count = BladeMcp::Importer.new(store, vault, concurrency: 3, log:).run(lists, **options)
    [count, log.string]
  end

  def messages(*seqs)
    seqs.to_h do |seq|
      headers = {'Message-ID' => "<#{seq}@x>", 'In-Reply-To' => ("<#{seq - 1}@x>" if seq > 1)}
      [['ruby-dev', seq], raw_mail(subject: "post #{seq}", headers:)]
    end
  end

  def stored
    db[:messages].order(:seq).select_map(:seq)
  end

  def test_imports_everything_and_links_replies
    count, = run_importer(FakeVault.new(messages(1, 2, 3)))
    assert_equal 3, count
    assert_equal [1, 2, 3], stored
    assert_equal store.find('ruby-dev', 2)[:id], store.find('ruby-dev', 3)[:parent_id]
  end

  def test_update_only_takes_keys_above_the_last_one_stored
    run_importer(FakeVault.new(messages(1, 2)))
    db[:messages].where(seq: 2).update(subject: 'kept')
    count, = run_importer(FakeVault.new(messages(1, 2, 3, 4)), only_new: true)
    assert_equal 2, count
    assert_equal 'kept', store.find('ruby-dev', 2)[:subject]
    assert_equal [1, 2, 3, 4], stored
  end

  def test_limit_takes_the_first_messages_of_each_list
    run_importer(FakeVault.new(messages(1, 2, 3)), limit: 2)
    assert_equal [1, 2], stored
  end

  def test_skips_messages_that_cannot_be_parsed_or_are_empty
    broken = +'raw'
    def broken.b = raise(ArgumentError, 'broken')
    count, log = run_importer(FakeVault.new(messages(1).merge(['ruby-dev', 2] => '', ['ruby-dev', 3] => broken)))
    assert_equal 1, count
    assert_match 'ruby-dev:2 is missing or empty', log
    assert_match 'ruby-dev:3 not parsed: ArgumentError: broken', log
  end

  def test_fetch_errors_stop_the_run
    vault = FakeVault.new(messages(1).merge(['ruby-dev', 2] => Seahorse::Client::NetworkingError.new(IOError.new)))
    assert_raises(Seahorse::Client::NetworkingError) { run_importer(vault) }
  end
end
