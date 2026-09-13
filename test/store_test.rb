# frozen_string_literal: true

require 'test_helper'

class StoreTest < BladeMcp::TestCase
  def post(list, seq, id, replying_to: [], date: "Sat, 09 Dec 2006 04:#{format('%02d', seq % 60)}:00 +0900", **mail)
    headers = {'Message-ID' => "<#{id}>", 'References' => replying_to.map { "<#{_1}>" }.join(' ')}
    save(list, seq, date:, headers: headers.reject { |_, value| value.empty? }, **mail)
  end

  def parent_of(list, seq)
    row = store.find(list, seq)
    store.ref(row['parent_id'])&.values_at('list', 'seq') if row['parent_id']
  end

  def test_links_replies_by_the_nearest_reference_in_the_same_list
    post 'ruby-dev', 1, 'root@x'
    post 'ruby-dev', 2, 'a@x', replying_to: %w[root@x]
    post 'ruby-dev', 3, 'b@x', replying_to: %w[root@x a@x]
    assert_equal 2, store.resolve_parents
    assert_equal ['ruby-dev', 1], parent_of('ruby-dev', 2)
    assert_equal ['ruby-dev', 2], parent_of('ruby-dev', 3)
  end

  def test_prefers_the_same_list_and_falls_back_to_another_list
    post 'ruby-core', 1, 'cross@x'
    post 'ruby-dev', 1, 'root@x'
    post 'ruby-dev', 2, 'reply@x', replying_to: %w[root@x cross@x]
    post 'ruby-dev', 3, 'other@x', replying_to: %w[cross@x]
    store.resolve_parents
    assert_equal ['ruby-dev', 1], parent_of('ruby-dev', 2)
    assert_equal ['ruby-core', 1], parent_of('ruby-dev', 3)
  end

  def test_falls_back_to_a_citation_in_the_body
    post 'ruby-list', 3486, 'old@x'
    save 'ruby-list', 3490, subject: 'Re: eval', body: "In [ruby-list :03486 ] the message:\n"
    save 'ruby-list', 3491, subject: 'unrelated', body: "see [ruby-list:3486]\n"
    store.resolve_parents
    assert_equal ['ruby-list', 3486], parent_of('ruby-list', 3490)
    assert_nil parent_of('ruby-list', 3491)
  end

  def test_thread_lists_the_whole_tree_from_the_root_in_date_order
    post 'ruby-dev', 1, 'root@x'
    post 'ruby-dev', 2, 'a@x', replying_to: %w[root@x]
    post 'ruby-dev', 3, 'b@x', replying_to: %w[root@x]
    post 'ruby-dev', 4, 'c@x', replying_to: %w[root@x a@x]
    post 'ruby-dev', 5, 'unrelated@x'
    store.resolve_parents
    rows = store.thread(store.find('ruby-dev', 4)['id'])
    assert_equal [[1, 0, nil], [2, 1, 1], [3, 1, 1], [4, 2, 2]], rows.map { _1.values_at('seq', 'depth', 'parent_seq') }
  end

  def test_thread_survives_a_parent_cycle
    post 'ruby-dev', 1, 'a@x'
    post 'ruby-dev', 2, 'b@x'
    a, b = [1, 2].map { store.find('ruby-dev', _1)['id'] }
    conn.exec_params('UPDATE messages SET parent_id = $2 WHERE id = $1', [a, b])
    conn.exec_params('UPDATE messages SET parent_id = $2 WHERE id = $1', [b, a])
    assert_equal [1, 2], store.thread(a).map { _1['seq'] }.sort
  end

  def test_reimport_keeps_the_embedding_only_when_the_text_is_unchanged
    id = save('ruby-dev', 1, body: "same\n")
    conn.exec_params('UPDATE messages SET embedding = $2::vector WHERE id = $1', [id, vector(0)])
    save('ruby-dev', 1, body: "same\n")
    assert conn.exec('SELECT embedding IS NOT NULL FROM messages').getvalue(0, 0)
    save('ruby-dev', 1, body: "changed\n")
    refute conn.exec('SELECT embedding IS NOT NULL FROM messages').getvalue(0, 0)
  end

  def test_reimport_keeps_a_skip_mark_only_when_the_text_is_unchanged
    id = save('ruby-dev', 1, body: "same\n")
    conn.exec_params('UPDATE messages SET embedding_skipped = true WHERE id = $1', [id])
    save('ruby-dev', 1, body: "same\n")
    assert conn.exec('SELECT embedding_skipped FROM messages').getvalue(0, 0)
    save('ruby-dev', 1, body: "changed\n")
    refute conn.exec('SELECT embedding_skipped FROM messages').getvalue(0, 0)
  end
end
