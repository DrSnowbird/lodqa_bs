# frozen_string_literal: true

class Search < ApplicationRecord
  # Subscribe search
  module Subscribable
    TRANSMIT_DATA_SIZE_UPPER_LIMIT = 500_000
    OFFSET_SIZE = 100

    extend ActiveSupport::Concern

    def subscribe url
      subsribe_serach_if_running self, url
      notify_existing_events_to url, self
    rescue Errno::ECONNREFUSED, Net::OpenTimeout, SocketError => e
      logger.info "Establishing TCP connection to #{url} failed. Error: #{e.inspect}"
    end

    private

    # There is no trigger to delete subscription of finished search.
    def subsribe_serach_if_running search, url
      search.not_finished? do
        DbConnection.using { SubscriptionContainer.add_for search, url }
      end
    end

    def notify_existing_events_to url, search
      Event.occurred_for(search, OFFSET_SIZE).each { |e| JSONResource.append_all url, *(split e) }
    end

    # Split events
    def split events
      divided = divide_into_size TRANSMIT_DATA_SIZE_UPPER_LIMIT, events
      divided.map { |e| { events: e } }
    end

    # Divide the event array into a size approximate to the transmission data size upper limit.
    def divide_into_size upper_limit, events
      return events unless events.any?

      total_size = events.to_json.length
      return [events] if total_size <= upper_limit

      # One transmission data size is calculated by the number of events.
      # Please note that if an event is huge, the send data size limit may be exceeded.
      number_of_chunk = total_size.fdiv(TRANSMIT_DATA_SIZE_UPPER_LIMIT).ceil
      chunk_size = events.length / number_of_chunk
      events.each_slice(chunk_size).to_a
    end
  end
end
