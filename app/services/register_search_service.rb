# frozen_string_literal: true

# Bussiness logic about registering a serach
module ReigsterSearchService
  class << self
    # Register a search.
    # Start a new search job unless same search exists.
    # Call back only if same search exists.
    def register search
      dupulicate_search = Search.equals_in search

      return start_new_job_for search unless dupulicate_search

      call_back_events_about dupulicate_search
    end

    private

    # Call back events about an exiting search.
    def call_back_events_about search
      case search.state
      # when :aborted Aborted seraches do not match new queries.
      # when :queued Callbacks will be called after the job start.
      when :running
        EventSender.send_to search.start_search_callback_url,
                            search.data_for_start_event
      when :finished
        EventSender.send_to search.start_search_callback_url,
                            search.data_for_start_event
        EventSender.send_to search.finish_search_callback_url,
                            search.dafa_for_finish_event
      end

      search.search_id
    end

    # Start new job for new search.
    def start_new_job_for search
      job = SearchJob.perform_later
      search.search_id = job.job_id
      search.save!
      search.search_id
    end
  end
end
