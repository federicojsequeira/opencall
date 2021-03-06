require 'csv'

class SessionProposal < ActiveRecord::Base
  include Searchable
  include Workflow

  belongs_to :user
  has_many :comments
  has_and_belongs_to_many :tags, autosave: true
  accepts_nested_attributes_for :tags, allow_destroy: true
  belongs_to :track
  belongs_to :audience
  belongs_to :theme
  has_many :reviews

  validates :title, :summary, :description, :user_id, :track_id, :audience_id, :video_link, presence: true

  workflow do
    state :new do
      event :accept, :transitions_to => :accepted
      event :decline, :transitions_to => :declined
    end
    state :accepted
    state :declined
  end

  mapping do
    indexes :title, search_analyzer: 'search_analyzer', analyzer: 'index_analyzer'
    indexes :video_link, index: :not_analyzed
    indexes :author, type: "object" do 
      indexes :name, search_analyzer: 'search_analyzer', analyzer: 'index_analyzer'
      indexes :avatar_url, index: :not_analyzed
    end
  end

  def autosave_associated_records_for_tags
    session_tags = []
    self.tags.each { |tag| session_tags << Tag.find_or_create_by(name: tag.name) unless tag.marked_for_destruction? }
    self.tags = session_tags
  end

  def as_indexed_json options={}
    JSON.parse build_as_document
  end

  def self.custom_search terms='', page_number=1
    query = terms.blank? ? self.match_all_query : self.aggregated_query(terms)
    search(query).page(page_number)
  end

  def self.aggregated_query terms
    Jbuilder.encode do |json|
      json.query do
        json.multi_match do
          json.fields ["tags^10", "theme^10", "track^10", "title^5", "summary", "author.name"]
          json.query terms
        end
      end
      json.highlight do
        json.fields do
          json.title "{}"
          json.summary "{}"
        end
      end
      json.aggregations do
        json.matched_tags do
          json.terms do
            json.field "tags"
          end
        end
      end
    end
  end

  def self.to_csv
    CSV.generate do |csv|
      csv << %w[session_proposal_id title theme audience audience_count track author country evaluation_1 evaluation_2 evaluation_3]
      SessionProposal.all.each do |s|
        row = [s.id, s.title, s.theme.name, s.audience.name, s.audience_count, s.track.name, s.user.full_name, s.user.country]
        s.reviews.each { |review| row << review.score }
        csv << row
      end
    end    
  end

  def self.match_all_query
    Jbuilder.encode do |json|
      json.query do
        json.match_all Hash.new
      end
    end
  end

  after_commit on: [:update] do
    __elasticsearch__.index_document
  end

  def reviewer_comments
    comments.where(user_id: Role.admins_and_reviewers.map(&:id))
  end

  def self.all_with_user_votes
    key = '#{s.id}||#{s.title}||#{s.theme.name}||#{s.user.full_name}'

    sessions = Hash[SessionProposal.all.map{|s| eval("\"#{key}\"")}.map {|s| [s, 0]}]
    User.all.each do |u| 
      SessionProposal.where(id: u.session_proposal_voted_ids).each {|s| sessions[eval("\"#{key}\"")] += 1}
    end
    session_with_votes = []
    sessions.each do |k,v|
      id, title, theme, author = k.split('||')
      session_with_votes << { id: id.to_i, title: title, theme: theme, author: author, votes: v }
    end
    session_with_votes
  end

  private
  def build_as_document
    Jbuilder.encode do |json|
      json.id           self.id
      json.title        self.title
      json.theme        self.theme.name
      json.track        self.track.name
      json.summary      self.summary
      json.author do
        json.name       self.user.full_name
        json.avatar_url self.user.avatar_url
      end
      json.video_link   self.video_link    
      json.tags         self.tags.map(&:name)
    end
  end
  def accept
    self.notified_on = DateTime.now
    save!
  end  
  def decline
    self.notified_on = DateTime.now
    save!
  end  
end
