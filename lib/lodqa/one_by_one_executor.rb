# frozen_string_literal: true

require 'logger/logger'
require 'logger/loggable'
require 'term/finder'
require 'lodqa/anchored_pgps'
require 'lodqa/graph_finder'
require 'lodqa/pgp_factory'
require 'enju_access/cgi_accessor'
require 'sparql_client/cacheable_client'

module Lodqa
  class OneByOneExecutor
    include Logger::Loggable

    attr_accessor :cancel_flag

    def initialize dataset,
                   query,
                   query_id,
                   parser_url: 'http://enju-gtrec.dbcls.jp',
                   urilinks_url: 'http://urilinks.lodqa.org',
                   read_timeout: 5,
                   sparql_limit: nil,
                   answer_limit: nil,
                   debug: false

      @target_dataset = dataset
      @query = query
      @default_parser_url = parser_url
      @urilinks_url = urilinks_url
      @read_timeout = read_timeout
      @sparql_limit = sparql_limit
      @answer_limit = answer_limit

      self.logger = Logger::Logger.new query_id, debug ? Logger::DEBUG : Logger::INFO

      # Flag to stop search
      @cancel_flag = false

      # For event emitting
      @event_hadlers = {}
      @event_data = {}

      @sparql_count = 0
    end

    # Bind event handler to events
    def on *events, &block
      return unless events.is_a? Array
      events.each do |e|
        @event_hadlers[e] = [] unless @event_hadlers[e]
        @event_hadlers[e].push block
      end
    end

    # Merage previouse event data and call all event handlers.
    def emit event, data
      @event_hadlers[event]&.each { |h| h.call event, data }
    end

    def perform
      dataset = {
        name: @target_dataset[:name],
        number: @target_dataset[:number]
      }
      emit :datasets, dataset: dataset

      # pgp
      emit :pgp, dataset: dataset, pgp: pgp

      # mappings
      mappings = mappings @target_dataset[:dictionary_url], pgp
      emit :mappings, dataset: dataset, pgp: pgp, mappings: mappings

      parallel = 16
      endpoint = SparqlClient::CacheableClient.new @target_dataset[:endpoint_url],
                                                   parallel,
                                                   method: :get,
                                                   read_timeout: @read_timeout
      endpoint.logger = logger

      start = Time.now
      count = 0
      queue = Queue.new # Wait finishing serach of all SPARQLs.
      known_sparql = Set.new # Skip serach when SPARQL is duplicated.

      anchored_pgps = AnchoredPgps.new pgp, mappings
      anchored_pgps.logger = logger
      anchored_pgps.each do |anchored_pgp|
        if @cancel_flag
          logger.debug "Stop during processing an anchored_pgp: #{anchored_pgp}"
          return
        end

        # GraphFinder(bgb)
        graph_finder_options = {
          max_hop: @target_dataset[:max_hop],
          ignore_predicates: @target_dataset[:ignore_predicates],
          sortal_predicates: @target_dataset[:sortal_predicates],
          sparql_limit: @sparql_limit,
          answer_limit: @answer_limit
        }
        graph_finder = GraphFinder.new endpoint, nil, graph_finder_options
        graph_finder.sparqls_of anchored_pgp do |bgp, sparql_query|
          if @cancel_flag
            logger.debug "Stop during processing an bgp: #{bgp}"
            return
          end

          # Skip querying duplicated SPARQL.
          next if known_sparql.member? sparql_query
          known_sparql << sparql_query

          @sparql_count += 1
          sparql = {
            query: sparql_query,
            number: @sparql_count
          }

          emit :sparql, dataset: dataset, pgp: pgp, mappings: mappings, anchored_pgp: anchored_pgp, bgp: bgp, sparql: sparql

          # Get solutions of SPARQL
          get_solutions_of_sparql_async endpoint, dataset, pgp, mappings, anchored_pgp, bgp, sparql, queue

          # Emit an event to notify starting of querying the SPARQL.
          emit :query_sparql, dataset: dataset, pgp: pgp, mappings: mappings, anchored_pgp: anchored_pgp, bgp: bgp, sparql: sparql
          count += 1
        end
      end

      error = 0
      success = 0
      count.times do
        e, s = queue.pop
        error += 1 if e
        success += 1 if s
      end

      if (error + success).positive?
        stats = {
          parallel: parallel,
          duration: Time.now - start,
          dataset: dataset,
          sparqls: error + success,
          error: error,
          success: success,
          error_rate: error / (error + success).to_f
        }

        logger.info "Finish stats: #{JSON.pretty_generate stats}"
      end
    rescue EnjuAccess::EnjuError => e
      logger.debug e.message
      emit :gateway_error,
           error_message: 'enju access error'
    rescue Term::FindError => e
      logger.debug e.message
      emit :gateway_error,
           error_message: 'dictionary lookup error'
    rescue SparqlClient::EndpointError => e
      logger.debug "The SPARQL Endpoint #{e.endpoint_name} has a persistent error, continue to the next Endpoint", error_message: e.message
    rescue StandardError => e
      logger.error e
    end

    private

    def get_solutions_of_sparql_async endpoint, dataset, pgp, mappings, anchored_pgp, bgp, sparql, queue
      # Get solutions of SPARQL
      endpoint.query_async sparql[:query] do |e, result|
        case e
        when nil
          # Convert to a hash object that contains only simple strings from array of RDF::Query::Solution.
          solutions = result.map { |s| s.map { |k, v| [k, v.to_s] }.to_h }

          emit :solutions, dataset: dataset, pgp: pgp, mappings: mappings, anchored_pgp: anchored_pgp, bgp: bgp, sparql: sparql, solutions: solutions

          # Find the answer of the solutions.
          solutions.each do |solution|
            solution
              .select { |id| anchored_pgp[:focus] == id.to_s.gsub(/^i/, '') } # The answer is instance node of focus node.
              .each { |_, uri| get_label_of_url endpoint, dataset, pgp, mappings, anchored_pgp, bgp, sparql, solutions, solution, uri }
          end
        when SparqlClient::EndpointTimeoutError
          logger.debug "The SPARQL Endpoint #{e.endpoint_name} return a timeout error for #{e.sparql}, continue to the next SPARQL", error_message: e.message
          emit :solutions,
               dataset: dataset, pgp: pgp, mappings: mappings, anchored_pgp: anchored_pgp, bgp: bgp, sparql: sparql, solutions: [],
               error: 'sparql timeout error'
        when SparqlClient::EndpointTemporaryError
          logger.info "The SPARQL Endpoint #{e.endpoint_name} return a temporary error for #{e.sparql}, continue to the next SPARQL", error_message: e.message
          emit :solutions,
               dataset: dataset, pgp: pgp, mappings: mappings, anchored_pgp: anchored_pgp, bgp: bgp, sparql: sparql, solutions: [],
               error_message: 'endopoint temporary error'
        else
          logger.error e
        end

        queue.push [e, result]
      end
    end

    def get_label_of_url endpoint, dataset, pgp, mappings, anchored_pgp, bgp, sparql, solutions, solution, uri
      # WebSocket message will be disorderd if additional informations are get ascynchronously
      label = label endpoint, uri
      urls, first_rendering = forwarded_urls uri

      emit :answer,
           dataset: dataset, pgp: pgp, mappings: mappings, anchored_pgp: anchored_pgp, bgp: bgp, sparql: sparql, solutions: solutions,
           solution: solution,
           answer: { uri: uri, label: label, urls: urls&.select { |u| u[:forwarding][:url].length < 10_000 }, first_rendering: first_rendering }
    end

    def pgp
      @pgp ||= PGPFactory.create (@target_dataset[:parser_url] || @default_parser_url),
                                 @query
    end

    def mappings dictionary_url, pgp
      tf = Term::Finder.new dictionary_url
      tf.logger = logger
      keywords = pgp[:nodes].values.map { |n| n[:text] }.concat(pgp[:edges].map { |e| e[:text] })
      tf.find keywords
    end

    # Return label as stirng
    def label endpoint, uri
      query_for_solution = "select ?label where { <#{uri}>  rdfs:label ?label }"
      endpoint.query(query_for_solution).map { |s| s.to_h[:label] }.first.to_s
    end

    def forwarded_urls uri
      urls = RestClient.get "#{@urilinks_url}/url/translate.json?query=#{uri}" do |res|
        return nil unless res.code == 200

        JSON.parse(res.body, symbolize_names: true)[:results]
            .sort_by { |m| [- m[:matching_score], - m[:priority]] }
      end

      first_rendering = urls.find { |u| u.dig(:rendering, :mime_type)&.start_with? 'image' }&.dig :rendering
      [urls, first_rendering]
    rescue Errno::ECONNREFUSED, RestClient::Exceptions::ReadTimeout, SocketError => e
      logger.debug "Failed to conntect The URL forwarding DB at #{@urilinks_url}, continue to the next SPARQL", error_message: e.message
      nil
    end
  end
end
