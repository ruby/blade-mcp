# frozen_string_literal: true

require 'aws-sdk-s3'

module BladeMcp
  # Read-only access to the blade-data-vault bucket, which keeps every list
  # message as the original RFC822 source under <list>/<seq>.
  class Vault
    BUCKET = 'blade-data-vault'
    REGION = 'ap-northeast-1'
    # Skips stray keys such as ruby-list/581.jis, ruby-talk/441599.1 and
    # ruby-core/00001.
    KEY = %r{\Aruby-[a-z]+/([1-9][0-9]*)\z}

    def initialize(client = Aws::S3::Client.new(region: REGION))
      @client = client
    end

    # S3 lists keys in lexical order, so there is no way to start after a
    # given number and the whole list has to be enumerated.
    def seqs(list)
      @client.list_objects_v2(bucket: BUCKET, prefix: "#{list}/").each_page.flat_map do |page|
        page.contents.filter_map { |object| object.key[KEY, 1]&.to_i }
      end.sort
    end

    def fetch(list, seq)
      @client.get_object(bucket: BUCKET, key: "#{list}/#{seq}").body.read
    rescue Aws::S3::Errors::NoSuchKey
      nil
    end
  end
end
