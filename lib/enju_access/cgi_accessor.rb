# frozen_string_literal: true

#
# It takes a plain-English sentence as input and returns parsing results by accessing an Enju cgi server.
#
require 'rest-client'
require 'enju_access/enju_error'
require 'enju_access/graph'

module EnjuAccess; end unless defined? EnjuAccess

# An instance of this class connects to an Enju CGI server to parse a sentence.
class EnjuAccess::CGIAccessor
  attr_reader :enju

  # Noun-chunk elements
  # (Note that PRP is not included. For dialog analysis however PRP (personal pronoun) would need to be included.)
  NC_CAT      = %w[NN NNP CD FW JJ WP].freeze

  # Noun-chunk elements that may appear at the head position
  NC_HEAD_CAT = %w[NN NNP CD FW WP].freeze

  # wh-pronoun and wh-determiner
  WH_CAT      = %w[WP WDT].freeze

  # It initializes an instance of RestClient::Resource to connect to an Enju cgi server
  def initialize enju_url
    @enju = RestClient::Resource.new enju_url
    raise EnjuAccess::EnjuError, 'The URL of a web service of enju has to be passed as the first argument.' unless @enju.instance_of? RestClient::Resource
  end

  # It takes a plain-English sentence as input, and
  # returns a hash that represent various aspects
  # of the PAS and syntactic structure of the sentence.
  def parse sentence
    tokens, root     = get_parse(sentence)
    base_noun_chunks = get_base_noun_chunks(tokens)
    relations        = get_relations(tokens, base_noun_chunks)
    focus            = get_focus(tokens, base_noun_chunks, relations)

    {
      tokens: tokens, # The array of token parses
      root: root, # The index of the root word
      focus: focus, # The index of the focus word, i.e., the one modified by a _wh_-modifier
      base_noun_chunks: base_noun_chunks, # the array of base noun chunks
      relations: relations # Shortest paths between two heads
    }
  end

  private

  # It populates the instance variables, tokens and root
  def get_parse sentence
    return [[], nil] if sentence.nil? || sentence.strip.empty?
    sentence = sentence.strip

    response = @enju.get params: { sentence: sentence, format: 'conll' }
    case response.code
    when 200 # 200 means success
      raise EnjuAccess::EnjuError, 'Empty input.' if response.body =~ /^Empty line/
      raise EnjuAccess::EnjuError, 'Enju CGI server returns html instead of tsv' if response.headers[:content_type] == 'text/html'

      tokens = []

      # response is a parsing result in CONLL format.
      response.body.split(/\r?\n/).each_with_index do |t, i| # for each token analysis
        dat = t.split(/\t/, 7)
        token = {}
        token[:idx]  = i - 1 # use 0-oriented index
        token[:lex]  = dat[1].force_encoding('UTF-8')
        token[:base] = dat[2]
        token[:pos]  = dat[3]
        token[:cat]  = dat[4]
        token[:type] = dat[5]
        token[:args] = dat[6].split.collect { |a| type, ref = a.split(':'); [type, ref.to_i - 1] } if dat[6]
        tokens << token # '<<' is push operation
      end

      root = tokens.shift[:args][0][1]

      # get span offsets
      i = 0
      tokens.each do |t|
        i += 1 until sentence[i] !~ /[ \t\n]/
        t[:beg] = i
        t[:end] = i + t[:lex].length
        i = t[:end]
      end

      [tokens, root]
    else
      raise EnjuAccess::EnjuError, 'Enju CGI server dose not respond.'
    end
  end

  # It finds base noun chunks from the category pattern.
  # It assumes that the last word of a BNC is its head.
  def get_base_noun_chunks tokens
    base_noun_chunks = []
    beg = -1
    head = -1
    tokens.each_with_index do |t, i|
      beg  = t[:idx] if beg.negative? && NC_CAT.include?(t[:cat])
      head = t[:idx] if beg >= 0 && NC_HEAD_CAT.include?(t[:cat]) && t[:args].nil?
      next unless beg >= 0 && !NC_CAT.include?(t[:cat])
      head = t[:idx] if head.negative?
      base_noun_chunks << { head: head, beg: beg, end: tokens[i - 1][:idx] }
      beg = -1
      head = -1
    end

    if beg >= 0
      raise 'Strange parse!' if head.negative?
      base_noun_chunks << { head: head, beg: beg, end: tokens.last[:idx] }
    end

    base_noun_chunks
  end

  # It finds the shortest path between the head word of any two base noun chunks that are not interfered by other base noun chunks.
  def get_relations tokens, base_noun_chunks
    graph = Graph.new
    tokens.each do |t|
      next unless t[:args]
      t[:args].each do |_type, arg|
        graph.add_edge(t[:idx], arg, 1) if arg >= 0
      end
    end

    rels = []
    heads = base_noun_chunks.collect { |c| c[:head] }
    base_noun_chunks.combination(2) do |c|
      path = graph.shortest_path(c[0][:head], c[1][:head])
      s = path.shift
      o = path.pop
      rels << [s, path, o] if (path & heads).empty?
    end
    rels
  end

  # It returns the index of the "focus word."  For example, for the input
  #
  # What devices are used to treat heart failure?
  #
  # ...it will return 1 (devices).
  def get_focus tokens, base_noun_chunks, relations
    # find the wh-word
    # assumption: one query has only one wh-word
    wh_token = tokens.find { |t| WH_CAT.include?(t[:cat]) }

    if wh_token
      if wh_token[:args]
        wh_token[:args][0][1]
      else
        wh_rel = relations.find { |r| r[0] == wh_token[:idx] }
        if wh_rel && tokens[wh_rel[1][0]][:base] == 'be'
          # if apposition
          # remove the wh_token from BNCs
          base_noun_chunks.delete_at(0)
          # remove the relation from/to the wh_token
          relations.delete(wh_rel)
          # and return the apposition
          wh_rel[2]
        else
          wh_token[:idx]
        end
      end
    elsif base_noun_chunks.nil? || base_noun_chunks.empty?
      0
    else
      base_noun_chunks[0][:head]
    end
  end
end
