class Project < ActiveRecord::Base

  RECENT_STATUS_COUNT = 8
  DEFAULT_POLLING_INTERVAL = 30

  has_many :statuses,
    class_name: 'ProjectStatus',
    dependent: :destroy,
    before_add: :update_refreshed_at,
    after_add: :remove_outdated_status
  has_many :payload_log_entries
  belongs_to :aggregate_project

  serialize :last_ten_velocities, Array
  serialize :tracker_validation_status, Hash

  scope :enabled, where(enabled: true)
  scope :standalone, where(aggregate_project_id: nil)
  scope :with_statuses, joins(:statuses).uniq

  scope :updateable,
    enabled
  .where(webhooks_enabled: [nil, false])

  scope :tracker_updateable,
    enabled
  .where('tracker_auth_token is NOT NULL and tracker_project_id is NOT NULL')

  scope :displayable, lambda {|tags|
    scope = enabled
    return scope.tagged_with(tags) if tags
    scope
  }

  scope :tagged, lambda { |tags|
    return Project.tagged_with(tags) if tags
    all
  }

  acts_as_taggable

  validates :name, presence: true
  validates :type, presence: true

  before_create :generate_guid

  attr_accessible :aggregate_project_id,
    :code, :name, :enabled, :polling_interval, :type, :tag_list, :online, :building,
    :auth_password, :auth_username, :tracker_auth_token, :tracker_project_id, :tracker_online,
    :webhooks_enabled, :verify_ssl

  def self.project_specific_attributes
    columns.map(&:name).grep(/#{project_attribute_prefix}_/)
  end

  def self.with_aggregate_project aggregate_project_id, &block
    with_scope(find: where(aggregate_project_id: aggregate_project_id), &block)
  end

  def code
    super.presence || name.downcase.gsub(" ", '')[0..3]
  end

  def latest_status
    statuses.latest
  end

  def recent_statuses(count = RECENT_STATUS_COUNT)
    ProjectStatus.recent(self, count)
  end

  def status
    latest_status || ProjectStatus.new(project: self)
  end

  def green?
    online? && status.success?
  end

  def yellow?
    online? && !red? && !green?
  end

  def red?
    online? && latest_status.try(:success?) == false
  end

  def status_in_words
    if red?
      'failure'
    elsif green?
      'success'
    elsif yellow?
      'indeterminate'
    else
      'offline'
    end
  end

  def color
    return "white" unless online?
    return "green" if green?
    return "red" if red?
    return "yellow" if yellow?
  end

  def tracker_configured?
    tracker_project_id.present? && tracker_auth_token.present?
  end

  def red_since
    breaking_build.try(:published_at)
  end

  def red_build_count
    return 0 if breaking_build.nil? || !online?
    statuses.count(:conditions => ["id >= ?", breaking_build.id])
  end

  def feed_url
    raise NotImplementedError, "Must implement feed_url in subclasses"
  end

  def build_status_url
    raise NotImplementedError, "Must implement build_status_url in subclasses"
  end

  def tracker_project_url
    "https://www.pivotaltracker.com/services/v3/projects/#{tracker_project_id}"
  end

  def tracker_iterations_url
    "https://www.pivotaltracker.com/services/v3/projects/#{tracker_project_id}/iterations/done?offset=-10"
  end

  def tracker_current_iteration_url
    "https://www.pivotaltracker.com/services/v3/projects/#{tracker_project_id}/iterations/current_backlog"
  end

  def to_s
    name
  end

  def building?
    super
  end

  def current_build_url
  end

  def last_green
    @last_green ||= recent_statuses.green.first
  end

  def breaking_build
    @breaking_build ||= if last_green.nil?
                          recent_statuses.red.last
                        else
                          recent_statuses.red.where(["build_id > ?", last_green.build_id]).first
                        end
  end

  def has_auth?
    auth_username.present? || auth_password.present?
  end

  def tracker_project?
    tracker_project_id.present? &&  tracker_auth_token.present?
  end

  def payload
    raise NotImplementedError, "Must implement payload in subclasses"
  end

  def has_status?(status)
    statuses.where(build_id: status.build_id).any?
  end

  def has_dependencies?
    false
  end

  def generate_guid
    self.guid = SecureRandom.uuid
  end

  def as_json(options={})
    json = super # TODO: Remove before merge
    json["project_id"] = self.id
    json["build"] = super(
      only: [:code, :id, :statuses, :building],
      root: false)
      .merge({"published_at" => published_at})
      .merge({"status" => status_in_words})
      .merge({"statuses" => statuses.reverse_chronological})
      .merge({"current_build_url" => current_build_url })
      json["tracker"] = super(
        only: [:tracker_online, :current_velocity, :last_ten_velocities, :stories_to_accept_count, :open_stories_count],
        methods: ["variance"],
        root:false) if tracker_project_id?
        json
  end

  def variance
    if last_ten_velocities.any?
      calculated_variance
    else
      0
    end
  end

  def handler
    ProjectWorkloadHandler.new(self)
  end

  def published_at
    latest_status.try(:published_at)
  end

  def record_failure!
    if enabled
      if failures < 3
        self.update_attribute(:failures, failures + 1)
        return false
      else
        self.update_attribute(:failures, 0)
        self.update_attribute(:enabled, false)
        return true
      end
    end
  end

  private

  def calculated_variance
    sample_variance.round(2)
  end

  def sample_variance
    mean = last_ten_velocities.sum / Float(last_ten_velocities.length)
    sum = last_ten_velocities.inject(0.0) do |accum, velocity|
      accum + ((velocity - mean)**2)
    end
    sum = sum / Float(last_ten_velocities.size)
  end

  def self.project_attribute_prefix
    name.match(/(.*)Project/)[1].underscore
  end

  def update_refreshed_at(status)
    self.last_refreshed_at = Time.now if online?
  end

  def remove_outdated_status(status)
    if statuses.count > ProjectMonitor::Application.config.max_status
      keepers = statuses.order('created_at DESC').limit(ProjectMonitor::Application.config.max_status)
      ProjectStatus.delete_all(["project_id = ? AND id not in (?)", id, keepers]) if keepers.any?
    end
  end

  def fetch_statuses
    Delayed::Job.enqueue(StatusFetcher::Job.new(self), priority: 0)
  end

  def simple_statuses
    statuses.map(&:success)
  end

  def url_with_scheme url
    if url =~ %r{\Ahttps?://}
      url
    else
      "http://#{url}"
    end
  end
end
