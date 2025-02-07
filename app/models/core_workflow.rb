# Copyright (C) 2012-2023 Zammad Foundation, https://zammad-foundation.org/

class CoreWorkflow < ApplicationModel
  include ChecksClientNotification
  include CoreWorkflow::Assets

  default_scope { order(:priority, :id) }
  scope :active, -> { where(active: true) }
  scope :changeable, -> { where(changeable: true) }
  scope :object, ->(object) { where(object: [object, nil]) }

  store :preferences
  store :condition_saved
  store :condition_selected
  store :perform

  validates :name, presence: true

=begin

Runs the core workflow engine based on the current state of the object.

  perform_result = CoreWorkflow.perform(payload: {
                                          'event'      => 'core_workflow',
                                          'request_id' => 'ChecksCoreWorkflow.validate_workflows',
                                          'class_name' => 'Ticket',
                                          'screen'     => 'edit',
                                          'params'     => Ticket.first.attributes,
                                        }, user: User.find(3), assets: false)

=end

  def self.perform(payload:, user:, assets: {}, assets_in_result: true, result: {}, form_updater: false)
    CoreWorkflow::Result.new(payload: payload, user: user, assets: assets, assets_in_result: assets_in_result, result: result, form_updater: form_updater).run
  rescue => e
    return {} if e.is_a?(ArgumentError)
    raise e if !Rails.env.production?

    Rails.logger.error 'Error performing Core Workflow engine.'
    Rails.logger.error e
    {}
  end

=begin

Checks if the object matches a specific condition.

  CoreWorkflow.matches_selector?(
    id: Ticket.first.id,
    user: User.find(3),
    selector: {"ticket.state_id"=>{"operator"=>"is", "value"=>["4", "5", "1", "2", "7", "3"]}}
  )

=end

  def self.matches_selector?(id:, user:, selector:, class_name: 'Ticket', params: {}, screen: 'edit', request_id: 'ChecksCoreWorkflow.validate_workflows', event: 'core_workflow', check: 'saved')
    if id.present?
      params['id'] = id
    end

    CoreWorkflow::Result.new(payload: {
                               'event'      => event,
                               'request_id' => request_id,
                               'class_name' => class_name,
                               'screen'     => screen,
                               'params'     => params,
                             }, user: user, assets: false, assets_in_result: false).matches_selector?(selector: selector, check: check)
  rescue => e
    return {} if e.is_a?(ArgumentError)
    raise e if !Rails.env.production?

    Rails.logger.error 'Error performing Core Workflow engine.'
    Rails.logger.error e
    false
  end
end
