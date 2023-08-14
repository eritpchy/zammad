# Copyright (C) 2012-2023 Zammad Foundation, https://zammad-foundation.org/

class Ticket < ApplicationModel
  include CanBeImported
  include HasActivityStreamLog
  include ChecksClientNotification
  include CanCsvImport
  include ChecksHtmlSanitized
  include ChecksHumanChanges
  include HasHistory
  include HasTags
  include HasSearchIndexBackend
  include HasOnlineNotifications
  include HasLinks
  include HasObjectManagerAttributes
  include HasTaskbars
  include Ticket::CallsStatsTicketReopenLog
  include Ticket::EnqueuesUserTicketCounterJob
  include Ticket::ResetsPendingTimeSeconds
  include Ticket::SetsCloseTime
  include Ticket::SetsOnlineNotificationSeen
  include Ticket::TouchesAssociations
  include Ticket::TriggersSubscriptions
  include Ticket::ChecksReopenAfterCertainTime

  include ::Ticket::Escalation
  include ::Ticket::Subject
  include ::Ticket::Assets
  include ::Ticket::SearchIndex
  include ::Ticket::Search
  include ::Ticket::MergeHistory

  store :preferences
  after_initialize :check_defaults, if: :new_record?
  before_create  :check_generate, :check_defaults, :check_title, :set_default_state, :set_default_priority
  before_update  :check_defaults, :check_title, :reset_pending_time, :check_owner_active

  # This must be loaded late as it depends on the internal before_create and before_update handlers of ticket.rb.
  include Ticket::SetsLastOwnerUpdateTime

  include HasTransactionDispatcher

  # workflow checks should run after before_create and before_update callbacks
  include ChecksCoreWorkflow

  validates :group_id, presence: true

  activity_stream_permission 'ticket.agent'

  core_workflow_screens 'create_middle', 'edit', 'overview_bulk'

  activity_stream_attributes_ignored :organization_id, # organization_id will change automatically on user update
                                     :create_article_type_id,
                                     :create_article_sender_id,
                                     :article_count,
                                     :first_response_at,
                                     :first_response_escalation_at,
                                     :first_response_in_min,
                                     :first_response_diff_in_min,
                                     :close_at,
                                     :close_escalation_at,
                                     :close_in_min,
                                     :close_diff_in_min,
                                     :update_escalation_at,
                                     :update_in_min,
                                     :update_diff_in_min,
                                     :last_close_at,
                                     :last_contact_at,
                                     :last_contact_agent_at,
                                     :last_contact_customer_at,
                                     :last_owner_update_at,
                                     :preferences

  search_index_attributes_relevant :organization_id,
                                   :group_id,
                                   :state_id,
                                   :priority_id

  history_attributes_ignored :create_article_type_id,
                             :create_article_sender_id,
                             :article_count,
                             :preferences

  history_relation_object 'Ticket::Article', 'Mention', 'Ticket::SharedDraftZoom'

  validates :note, length: { maximum: 250 }
  sanitized_html :note

  belongs_to    :group, optional: true
  belongs_to    :organization, optional: true
  has_many      :articles,               class_name: 'Ticket::Article', after_add: :cache_update, after_remove: :cache_update, dependent: :destroy, inverse_of: :ticket
  has_many      :ticket_time_accounting, class_name: 'Ticket::TimeAccounting', dependent: :destroy, inverse_of: :ticket
  has_many      :flags,                  class_name: 'Ticket::Flag', dependent: :destroy
  has_many      :mentions,               as: :mentionable, dependent: :destroy
  has_one       :shared_draft,           class_name: 'Ticket::SharedDraftZoom', inverse_of: :ticket, dependent: :destroy
  belongs_to    :state,                  class_name: 'Ticket::State', optional: true
  belongs_to    :priority,               class_name: 'Ticket::Priority', optional: true
  belongs_to    :owner,                  class_name: 'User', optional: true
  belongs_to    :customer,               class_name: 'User', optional: true
  belongs_to    :created_by,             class_name: 'User', optional: true
  belongs_to    :updated_by,             class_name: 'User', optional: true
  belongs_to    :create_article_type,    class_name: 'Ticket::Article::Type', optional: true
  belongs_to    :create_article_sender,  class_name: 'Ticket::Article::Sender', optional: true

  association_attributes_ignored :flags, :mentions

  attr_accessor :callback_loop

=begin

processes tickets which have reached their pending time and sets next state_id

  processed_tickets = Ticket.process_pending

returns

  processed_tickets = [<Ticket>, ...]

=end

  def self.process_pending
    result = []

    # process pending action tickets
    pending_action = Ticket::StateType.find_by(name: 'pending action')
    ticket_states_pending_action = Ticket::State.where(state_type_id: pending_action)
                                                .where.not(next_state_id: nil)
    if ticket_states_pending_action.present?
      next_state_map = {}
      ticket_states_pending_action.each do |state|
        next_state_map[state.id] = state.next_state_id
      end

      tickets = where(state_id: next_state_map.keys)
                .where('pending_time <= ?', Time.zone.now)

      tickets.find_each(batch_size: 500) do |ticket|
        Transaction.execute do
          ticket.state_id      = next_state_map[ticket.state_id]
          ticket.updated_at    = Time.zone.now
          ticket.updated_by_id = 1
          ticket.save!
        end
        result.push ticket
      end
    end

    # process pending reminder tickets
    pending_reminder = Ticket::StateType.find_by(name: 'pending reminder')
    ticket_states_pending_reminder = Ticket::State.where(state_type_id: pending_reminder)

    if ticket_states_pending_reminder.present?
      reminder_state_map = {}
      ticket_states_pending_reminder.each do |state|
        reminder_state_map[state.id] = state.next_state_id
      end

      tickets = where(state_id: reminder_state_map.keys)
                .where('pending_time <= ?', Time.zone.now)

      tickets.find_each(batch_size: 500) do |ticket|

        article_id = nil
        article = Ticket::Article.last_customer_agent_article(ticket.id)
        if article
          article_id = article.id
        end

        # send notification
        TransactionJob.perform_now(
          object:     'Ticket',
          type:       'reminder_reached',
          object_id:  ticket.id,
          article_id: article_id,
          user_id:    1,
        )

        result.push ticket
      end
    end

    result
  end

  def auto_assign(user)
    return if !persisted?
    return if Setting.get('ticket_auto_assignment').blank?
    return if owner_id != 1
    return if !TicketPolicy.new(user, self).full?

    user_ids_ignore = Array(Setting.get('ticket_auto_assignment_user_ids_ignore')).map(&:to_i)
    return if user_ids_ignore.include?(user.id)

    ticket_auto_assignment_selector = Setting.get('ticket_auto_assignment_selector')
    return if ticket_auto_assignment_selector.blank?

    condition = ticket_auto_assignment_selector[:condition].merge(
      'ticket.id' => {
        'operator' => 'is',
        'value'    => id,
      }
    )

    ticket_count, = Ticket.selectors(condition, limit: 1, current_user: user, access: 'full')
    return if ticket_count.to_i.zero?

    update!(owner: user)
  end

=begin

processes escalated tickets

  processed_tickets = Ticket.process_escalation

returns

  processed_tickets = [<Ticket>, ...]

=end

  def self.process_escalation
    result = []

    # fetch all escalated and soon to be escalating tickets
    where('escalation_at <= ?', 15.minutes.from_now).find_each(batch_size: 500) do |ticket|

      article_id = nil
      article = Ticket::Article.last_customer_agent_article(ticket.id)
      if article
        article_id = article.id
      end

      # send escalation
      if ticket.escalation_at < Time.zone.now
        TransactionJob.perform_now(
          object:     'Ticket',
          type:       'escalation',
          object_id:  ticket.id,
          article_id: article_id,
          user_id:    1,
        )
        result.push ticket
        next
      end

      # check if warning needs to be sent
      TransactionJob.perform_now(
        object:     'Ticket',
        type:       'escalation_warning',
        object_id:  ticket.id,
        article_id: article_id,
        user_id:    1,
      )
      result.push ticket
    end
    result
  end

=begin

processes tickets which auto unassign time has reached

  processed_tickets = Ticket.process_auto_unassign

returns

  processed_tickets = [<Ticket>, ...]

=end

  def self.process_auto_unassign

    # process pending action tickets
    state_ids = Ticket::State.by_category(:work_on).pluck(:id)
    return [] if state_ids.blank?

    result = []
    groups = Group.where(active: true).where('assignment_timeout IS NOT NULL AND groups.assignment_timeout != 0')
    return [] if groups.blank?

    groups.each do |group|
      next if group.assignment_timeout.blank?

      ticket_ids = Ticket.where('state_id IN (?) AND owner_id != 1 AND group_id = ? AND last_owner_update_at IS NOT NULL', state_ids, group.id).limit(600).pluck(:id)
      ticket_ids.each do |ticket_id|
        ticket = Ticket.find_by(id: ticket_id)
        next if !ticket

        minutes_since_last_assignment = Time.zone.now - ticket.last_owner_update_at
        next if (minutes_since_last_assignment / 60) <= group.assignment_timeout

        Transaction.execute do
          ticket.owner_id      = 1
          ticket.updated_at    = Time.zone.now
          ticket.updated_by_id = 1
          ticket.save!
        end
        result.push ticket
      end
    end

    result
  end

=begin

merge tickets

  ticket = Ticket.find(123)
  result = ticket.merge_to(
    ticket_id: 123,
    user_id:   123,
  )

returns

  result = true|false

=end

  def merge_to(data)

    # prevent cross merging tickets
    target_ticket = Ticket.find_by(id: data[:ticket_id])
    raise 'no target ticket given' if !target_ticket
    raise Exceptions::UnprocessableEntity, __('It is not possible to merge into an already merged ticket.') if target_ticket.state.state_type.name == 'merged'

    # check different ticket ids
    raise Exceptions::UnprocessableEntity, __('A ticket cannot be merged into itself.') if id == target_ticket.id

    # update articles
    Transaction.execute context: 'merge' do

      Ticket::Article.where(ticket_id: id).each(&:touch)

      # quiet update of reassign of articles
      Ticket::Article.where(ticket_id: id).update_all(['ticket_id = ?', data[:ticket_id]]) # rubocop:disable Rails/SkipsModelValidations

      # mark target ticket as updated
      # otherwise the "received_merge" history entry
      # will be the same as the last updated_at
      # which might be a long time ago
      target_ticket.updated_at = Time.zone.now

      # add merge event to both ticket's history (Issue #2469 - Add information "Ticket merged" to History)
      target_ticket.history_log(
        'received_merge',
        data[:user_id],
        id_to:   target_ticket.id,
        id_from: id,
      )
      history_log(
        'merged_into',
        data[:user_id],
        id_to:   target_ticket.id,
        id_from: id,
      )

      # create new merge article
      Ticket::Article.create(
        ticket_id:     id,
        type_id:       Ticket::Article::Type.lookup(name: 'note').id,
        sender_id:     Ticket::Article::Sender.lookup(name: 'Agent').id,
        body:          'merged',
        internal:      false,
        created_by_id: data[:user_id],
        updated_by_id: data[:user_id],
      )

      # search for mention duplicates and destroy them before moving mentions
      Mention.duplicates(self, target_ticket).destroy_all
      Mention.where(mentionable: self).update_all(mentionable_id: target_ticket.id) # rubocop:disable Rails/SkipsModelValidations

      # reassign links to the new ticket
      # rubocop:disable Rails/SkipsModelValidations
      ticket_source_id = Link::Object.find_by(name: 'Ticket').id

      # search for all duplicate source and target links and destroy them
      # before link merging
      Link.duplicates(
        object1_id:    ticket_source_id,
        object1_value: id,
        object2_value: data[:ticket_id]
      ).destroy_all
      Link.where(
        link_object_source_id:    ticket_source_id,
        link_object_source_value: id,
      ).update_all(link_object_source_value: data[:ticket_id])
      Link.where(
        link_object_target_id:    ticket_source_id,
        link_object_target_value: id,
      ).update_all(link_object_target_value: data[:ticket_id])
      # rubocop:enable Rails/SkipsModelValidations

      # link tickets
      Link.add(
        link_type:                'parent',
        link_object_source:       'Ticket',
        link_object_source_value: data[:ticket_id],
        link_object_target:       'Ticket',
        link_object_target_value: id
      )

      # external sync references
      ExternalSync.migrate('Ticket', id, target_ticket.id)

      # set state to 'merged'
      self.state_id = Ticket::State.lookup(name: 'merged').id

      # rest owner
      self.owner_id = 1

      # save ticket
      save!

      # touch new ticket (to broadcast change)
      target_ticket.touch # rubocop:disable Rails/SkipsModelValidations

      EventBuffer.add('transaction', {
                        object:     target_ticket.class.name,
                        type:       'update.received_merge',
                        data:       target_ticket,
                        changes:    {},
                        id:         target_ticket.id,
                        user_id:    UserInfo.current_user_id,
                        created_at: Time.zone.now,
                      })

      EventBuffer.add('transaction', {
                        object:     self.class.name,
                        type:       'update.merged_into',
                        data:       self,
                        changes:    {},
                        id:         id,
                        user_id:    UserInfo.current_user_id,
                        created_at: Time.zone.now,
                      })
    end
    true
  end

=begin

check if online notification should be shown in general as already seen with current state

  ticket = Ticket.find(1)
  seen = ticket.online_notification_seen_state(user_id_check)

returns

  result = true # or false

=end

  def online_notification_seen_state(user_id_check = nil)
    state      = Ticket::State.lookup(id: state_id)
    state_type = Ticket::StateType.lookup(id: state.state_type_id)

    # always to set unseen for ticket owner and users which did not the update
    return false if state_type.name != 'merged' && user_id_check && user_id_check == owner_id && user_id_check != updated_by_id

    # set all to seen if pending action state is a closed or merged state
    if state_type.name == 'pending action' && state.next_state_id
      state      = Ticket::State.lookup(id: state.next_state_id)
      state_type = Ticket::StateType.lookup(id: state.state_type_id)
    end

    # set all to seen if new state is pending reminder state
    if state_type.name == 'pending reminder'
      if user_id_check
        return false if owner_id == 1
        return false if updated_by_id != owner_id && user_id_check == owner_id

        return true
      end
      return true
    end

    # set all to seen if new state is a closed or merged state
    return true if state_type.name == 'closed'
    return true if state_type.name == 'merged'

    false
  end

=begin

get count of tickets and tickets which match on selector

@param  [Hash] selectors hash with conditions
@oparam [Hash] options

@option options [String]  :access can be 'full', 'read', 'create' or 'ignore' (ignore means a selector over all tickets), defaults to 'full'
@option options [Integer] :limit of tickets to return
@option options [User]    :user is a current user
@option options [Integer] :execution_time is a current user

@return [Integer, [<Ticket>]]

@example
  ticket_count, tickets = Ticket.selectors(params[:condition], limit: limit, current_user: current_user, access: 'full')

  ticket_count # count of found tickets
  tickets      # tickets

=end

  def self.selectors(selectors, options)
    limit = options[:limit] || 10
    current_user = options[:current_user]
    access = options[:access] || 'full'
    raise 'no selectors given' if !selectors

    query, bind_params, tables = selector2sql(selectors, options)
    return [] if !query

    ActiveRecord::Base.transaction(requires_new: true) do

      if !current_user || access == 'ignore'
        ticket_count = Ticket.distinct.where(query, *bind_params).joins(tables).reorder(options[:order_by]).count
        tickets = Ticket.distinct.where(query, *bind_params).joins(tables).reorder(options[:order_by]).limit(limit)
        next [ticket_count, tickets]
      end

      tickets = "TicketPolicy::#{access.camelize}Scope".constantize
                                                       .new(current_user).resolve
                                                       .distinct
                                                       .where(query, *bind_params)
                                                       .joins(tables)
                                                       .reorder(options[:order_by])

      next [tickets.count, tickets.limit(limit)]
    rescue ActiveRecord::StatementInvalid => e
      Rails.logger.error e
      raise ActiveRecord::Rollback
    end
  end

=begin

generate condition query to search for tickets based on condition

  query_condition, bind_condition, tables = selector2sql(params[:condition], current_user: current_user)

condition example

  {
    'ticket.title' => {
      operator: 'contains', # contains not
      value: 'some value',
    },
    'ticket.state_id' => {
      operator: 'is',
      value: [1,2,5]
    },
    'ticket.created_at' => {
      operator: 'after (absolute)', # after,before
      value: '2015-10-17T06:00:00.000Z',
    },
    'ticket.created_at' => {
      operator: 'within next (relative)', # within next, within last, after, before
      range: 'day', # minute|hour|day|month|year
      value: '25',
    },
    'ticket.owner_id' => {
      operator: 'is', # is not
      pre_condition: 'current_user.id',
    },
    'ticket.owner_id' => {
      operator: 'is', # is not
      pre_condition: 'specific',
      value: 4711,
    },
    'ticket.escalation_at' => {
      operator: 'is not', # not
      value: nil,
    },
    'ticket.tags' => {
      operator: 'contains all', # contains all|contains one|contains all not|contains one not
      value: 'tag1, tag2',
    },
  }

=end

  def self.selector2sql(selectors, options = {})
    Ticket::Selector::Sql.new(selector: selectors, options: options).get
  end

=begin

perform changes on ticket

  ticket.perform_changes(trigger, 'trigger', item, current_user_id)

  # or

  ticket.perform_changes(job, 'job', item, current_user_id)

=end

  def perform_changes(performable, perform_origin, item = nil, current_user_id = nil, activator_type: nil)
    return if performable.try(:performable_on?, self, activator_type:) === false # rubocop:disable Style/CaseEquality

    perform = performable.perform
    logger.debug { "Perform #{perform_origin} #{perform.inspect} on Ticket.find(#{id})" }

    article = begin
      Ticket::Article.find_by(id: item.try(:dig, :article_id))
    rescue ArgumentError
      nil
    end

    # if the configuration contains the deletion of the ticket then
    # we skip all other ticket changes because they does not matter
    if perform['ticket.action'].present? && perform['ticket.action']['value'] == 'delete'
      perform.each_key do |key|
        (object_name, attribute) = key.split('.', 2)
        next if object_name != 'ticket'
        next if attribute == 'action'

        perform.delete(key)
      end
    end

    objects              = build_notification_template_objects(article)
    perform_notification = {}
    perform_article      = {}
    changed              = false
    perform.each do |key, value|
      (object_name, attribute) = key.split('.', 2)
      raise "Unable to update object #{object_name}.#{attribute}, only can update tickets, send notifications and create articles!" if object_name != 'ticket' && object_name != 'article' && object_name != 'notification'

      # send notification/create article (after changes are done)
      if object_name == 'article'
        perform_article[key] = value
        next
      end
      if object_name == 'notification'
        perform_notification[key] = value
        next
      end

      # Apply pending_time changes
      if perform_changes_date(object_name: object_name, attribute: attribute, value: value, performable: performable)
        changed = true
        next
      end

      # update tags
      if key == 'ticket.tags'
        next if value['value'].blank?

        tags = value['value'].split(',')
        case value['operator']
        when 'add'
          tags.each do |tag|
            tag_add(tag, current_user_id || 1, sourceable: performable)
          end
        when 'remove'
          tags.each do |tag|
            tag_remove(tag, current_user_id || 1, sourceable: performable)
          end
        else
          logger.error "Unknown #{attribute} operator #{value['operator']}"
        end
        next
      end

      # delete ticket
      if key == 'ticket.action'
        next if value['value'].blank?
        next if value['value'] != 'delete'

        logger.info { "Deleted ticket from #{perform_origin} #{perform.inspect} Ticket.find(#{id})" }
        destroy!
        next
      end

      # lookup pre_condition
      if value['pre_condition']
        if value['pre_condition'].start_with?('not_set')
          value['value'] = 1
        elsif value['pre_condition'].start_with?('current_user.')
          raise __("The required parameter 'current_user_id' is missing.") if !current_user_id

          value['value'] = current_user_id
        end
      end

      # update ticket
      next if self[attribute].to_s == value['value'].to_s

      changed = true

      if value['value'].is_a?(String)
        value['value'] = NotificationFactory::Mailer.template(
          templateInline: value['value'],
          objects:        objects,
          quote:          true,
        )
      end

      self[attribute] = value['value']
      history_change_source_attribute(performable, attribute)

      logger.debug { "set #{object_name}.#{attribute} = #{value['value'].inspect} for ticket_id #{id}" }
    end

    if changed
      save!
    end

    perform_article.each do |key, value|
      raise __("Article could not be created. An unsupported key other than 'article.note' was provided.") if key != 'article.note'

      add_trigger_note(id, value, objects, perform_origin, performable)
    end

    perform_notification.each do |key, value|

      # send notification
      case key
      when 'notification.sms'
        send_sms_notification(value, article, perform_origin, performable)
        next
      when 'notification.email'
        send_email_notification(value, article, perform_origin, performable)
      when 'notification.webhook'
        TriggerWebhookJob.perform_later(performable,
                                        self,
                                        article,
                                        changes:        human_changes(
                                          item.try(:dig, :changes),
                                          self,
                                        ),
                                        user_id:        item.try(:dig, :user_id),
                                        execution_type: perform_origin,
                                        event_type:     item.try(:dig, :type))
      end
    end

    performable.try(:performed_on, self, activator_type:)

    true
  end

  def perform_changes_date(object_name:, attribute:, value:, performable:)
    return if object_name != 'ticket'

    object_attribute = ObjectManager::Attribute.for_object('Ticket').find_by(name: attribute, data_type: %w[datetime date])
    return if object_attribute.blank?

    new_value = if value['operator'] == 'relative'
                  TimeRangeHelper.relative(range: value['range'], value: value['value'])
                else
                  value['value']
                end

    if new_value
      self[attribute] = if object_attribute[:data_type] == 'datetime'
                          new_value.to_datetime
                        else
                          new_value.to_date
                        end

      history_change_source_attribute(performable, attribute)
    end

    true
  end

=begin

perform changes on ticket

  ticket.add_trigger_note(ticket_id, note, objects, perform_origin)

=end

  def add_trigger_note(ticket_id, note, objects, perform_origin, performable)
    rendered_subject = NotificationFactory::Mailer.template(
      templateInline: note[:subject],
      objects:        objects,
      quote:          true,
    )

    rendered_body = NotificationFactory::Mailer.template(
      templateInline: note[:body],
      objects:        objects,
      quote:          true,
    )

    article = Ticket::Article.new(
      ticket_id:     ticket_id,
      subject:       rendered_subject,
      content_type:  'text/html',
      body:          rendered_body,
      internal:      note[:internal],
      sender:        Ticket::Article::Sender.find_by(name: 'System'),
      type:          Ticket::Article::Type.find_by(name: 'note'),
      preferences:   {
        perform_origin: perform_origin,
        notification:   true,
      },
      updated_by_id: 1,
      created_by_id: 1,
    )
    article.history_change_source_attribute(performable, 'created')
    article.save!
  end

=begin

perform active triggers on ticket

  Ticket.perform_triggers(ticket, article, triggers, item, triggers, options)

=end

  def self.perform_triggers(ticket, article, triggers, item, options = {})
    recursive = Setting.get('ticket_trigger_recursive')
    type = options[:type] || item[:type]
    local_options = options.clone
    local_options[:type] = type
    local_options[:reset_user_id] = true
    local_options[:disable] = ['Transaction::Notification']
    local_options[:trigger_ids] ||= {}
    local_options[:trigger_ids][ticket.id.to_s] ||= []
    local_options[:loop_count] ||= 0
    local_options[:loop_count] += 1

    ticket_trigger_recursive_max_loop = Setting.get('ticket_trigger_recursive_max_loop')&.to_i || 10
    if local_options[:loop_count] > ticket_trigger_recursive_max_loop
      message = "Stopped perform_triggers for this object (Ticket/#{ticket.id}), because loop count was #{local_options[:loop_count]}!"
      logger.info { message }
      return [false, message]
    end

    return [true, __('No triggers active')] if triggers.blank?

    # check if notification should be send because of customer emails
    send_notification = true
    if local_options[:send_notification] == false
      send_notification = false
    elsif item[:article_id]
      article = Ticket::Article.lookup(id: item[:article_id])
      if article&.preferences && article.preferences['send-auto-response'] == false
        send_notification = false
      end
    end

    Transaction.execute(local_options) do
      triggers.each do |trigger|
        logger.debug { "Probe trigger (#{trigger.name}/#{trigger.id}) for this object (Ticket:#{ticket.id}/Loop:#{local_options[:loop_count]})" }

        user_id = ticket.updated_by_id
        if article
          user_id = article.updated_by_id
        end

        user = User.lookup(id: user_id)

        # verify is condition is matching
        ticket_count, tickets = Ticket.selectors(
          trigger.condition,
          limit:            1,
          execution_time:   true,
          current_user:     user,
          access:           'ignore',
          ticket_action:    type,
          ticket_id:        ticket.id,
          article_id:       article&.id,
          changes:          item[:changes],
          changes_required: trigger.condition_changes_required?
        )

        next if ticket_count.blank?
        next if ticket_count.zero?
        next if tickets.take.id != ticket.id

        if recursive == false && local_options[:loop_count] > 1
          message = "Do not execute recursive triggers per default until Zammad 3.0. With Zammad 3.0 and higher the following trigger is executed '#{trigger.name}' on Ticket:#{ticket.id}. Please review your current triggers and change them if needed."
          logger.info { message }
          return [true, message]
        end

        if article && send_notification == false && trigger.perform['notification.email'] && trigger.perform['notification.email']['recipient']
          recipient = trigger.perform['notification.email']['recipient']
          local_options[:send_notification] = false
          if recipient.include?('ticket_customer') || recipient.include?('article_last_sender')
            logger.info { "Skip trigger (#{trigger.name}/#{trigger.id}) because sender do not want to get auto responder for object (Ticket/#{ticket.id}/Article/#{article.id})" }
            next
          end
        end

        if local_options[:trigger_ids][ticket.id.to_s].include?(trigger.id)
          logger.info { "Skip trigger (#{trigger.name}/#{trigger.id}) because was already executed for this object (Ticket:#{ticket.id}/Loop:#{local_options[:loop_count]})" }
          next
        end
        local_options[:trigger_ids][ticket.id.to_s].push trigger.id
        logger.info { "Execute trigger (#{trigger.name}/#{trigger.id}) for this object (Ticket:#{ticket.id}/Loop:#{local_options[:loop_count]})" }

        ticket.perform_changes(trigger, 'trigger', item, user_id, activator_type: type)

        if recursive == true
          TransactionDispatcher.commit(local_options)
        end
      end
    end
    [true, ticket, local_options]
  end

=begin

get all email references headers of a ticket, to exclude some, parse it as array into method

  references = ticket.get_references

result

  ['message-id-1234', 'message-id-5678']

ignore references header(s)

  references = ticket.get_references(['message-id-5678'])

result

  ['message-id-1234']

=end

  def get_references(ignore = [])
    references = []
    Ticket::Article.select('in_reply_to, message_id').where(ticket_id: id).each do |article|
      if article.in_reply_to.present?
        references.push article.in_reply_to
      end
      next if article.message_id.blank?

      references.push article.message_id
    end
    ignore.each do |item|
      references.delete(item)
    end
    references
  end

=begin

get all articles of a ticket in correct order (overwrite active record default method)

  articles = ticket.articles

result

  [article1, article2]

=end

  def articles
    Ticket::Article.where(ticket_id: id).reorder(:created_at, :id)
  end

  # Get whichever #last_contact_* was later
  # This is not identical to #last_contact_at
  # It returns time to last original (versus follow up) contact
  # @return [Time, nil]
  def last_original_update_at
    [last_contact_agent_at, last_contact_customer_at].compact.max
  end

  # true if conversation did happen and agent responded
  # false if customer is waiting for response or agent reached out and customer did not respond yet
  # @return [Bool]
  def agent_responded?
    return false if last_contact_customer_at.blank?
    return false if last_contact_agent_at.blank?

    last_contact_customer_at < last_contact_agent_at
  end

=begin

Get the color of the state the current ticket is in

  ticket.current_state_color

returns a hex color code

=end
  def current_state_color
    return '#f35912' if escalation_at && escalation_at < Time.zone.now

    case state.state_type.name
    when 'new', 'open'
      return '#faab00'
    when 'closed'
      return '#38ad69'
    when 'pending reminder'
      return '#faab00' if pending_time && pending_time < Time.zone.now
    end

    '#000000'
  end

  def mention_user_ids
    mentions.pluck(:user_id)
  end

  private

  def check_generate
    return true if number

    self.number = Ticket::Number.generate
    true
  end

  def check_title
    return true if !title

    title.gsub!(%r{\s|\t|\r}, ' ')
    true
  end

  def check_defaults
    check_default_owner
    check_default_organization
    true
  end

  def check_default_owner
    return if !has_attribute?(:owner_id)
    return if owner_id || owner

    self.owner_id = 1
  end

  def check_default_organization
    return if !has_attribute?(:organization_id)
    return if !customer_id

    customer = User.find_by(id: customer_id)
    return if !customer
    return if organization_id.present? && customer.organization_id?(organization_id)
    return if organization.present? && customer.organization_id?(organization.id)

    self.organization_id = customer.organization_id
  end

  def reset_pending_time

    # ignore if no state has changed
    return true if !changes_to_save['state_id']

    # ignore if new state is blank and
    # let handle ActiveRecord the error
    return if state_id.blank?

    # check if new state isn't pending*
    current_state      = Ticket::State.lookup(id: state_id)
    current_state_type = Ticket::StateType.lookup(id: current_state.state_type_id)

    # in case, set pending_time to nil
    return true if current_state_type.name.match?(%r{^pending}i)

    self.pending_time = nil
    true
  end

  def set_default_state
    return true if state_id

    default_ticket_state = Ticket::State.find_by(default_create: true)
    return true if !default_ticket_state

    self.state_id = default_ticket_state.id
    true
  end

  def set_default_priority
    return true if priority_id

    default_ticket_priority = Ticket::Priority.find_by(default_create: true)
    return true if !default_ticket_priority

    self.priority_id = default_ticket_priority.id
    true
  end

  def check_owner_active
    return true if Setting.get('import_mode')

    # only change the owner for non closed Tickets for historical/reporting reasons
    return true if state.present? && Ticket::StateType.lookup(id: state.state_type_id)&.name == 'closed'

    # return when ticket is unassigned
    return true if owner_id.blank?
    return true if owner_id == 1

    # return if owner is active, is agent and has access to group of ticket
    return true if owner.active? && owner.permissions?('ticket.agent') && owner.group_access?(group_id, 'full')

    # else set the owner of the ticket to the default user as unassigned
    self.owner_id = 1
    true
  end

  # articles.last breaks (returns the wrong article)
  # if another email notification trigger preceded this one
  # (see https://github.com/zammad/zammad/issues/1543)
  def build_notification_template_objects(article)
    last_article = nil
    last_internal_article = nil
    last_external_article = nil
    all_articles = articles

    if article.nil?
      last_article = all_articles.last
      last_internal_article = all_articles.reverse.find(&:internal?)
      last_external_article = all_articles.reverse.find { |a| !a.internal? }
    else
      last_article = article
      last_internal_article = article.internal? ? article : all_articles.reverse.find(&:internal?)
      last_external_article = article.internal? ? all_articles.reverse.find { |a| !a.internal? } : article
    end

    {
      ticket:                   self,
      article:                  last_article,
      last_article:             last_article,
      last_internal_article:    last_internal_article,
      last_external_article:    last_external_article,
      created_article:          article,
      created_internal_article: article&.internal? ? article : nil,
      created_external_article: article&.internal? ? nil : article,
    }
  end

  def send_email_notification(value, article, perform_origin, performable)
    # value['recipient'] was a string in the past (single-select) so we convert it to array if needed
    value_recipient = Array(value['recipient'])

    recipients_raw = []
    value_recipient.each do |recipient|
      case recipient
      when 'article_last_sender'
        if article.present?
          if article.reply_to.present?
            recipients_raw.push(article.reply_to)
          elsif article.from.present?
            recipients_raw.push(article.from)
          elsif article.origin_by_id
            email = User.find_by(id: article.origin_by_id).email
            recipients_raw.push(email)
          elsif article.created_by_id
            email = User.find_by(id: article.created_by_id).email
            recipients_raw.push(email)
          end
        end
      when 'ticket_customer'
        email = User.find_by(id: customer_id).email
        recipients_raw.push(email)
      when 'ticket_owner'
        email = User.find_by(id: owner_id).email
        recipients_raw.push(email)
      when 'ticket_agents'
        User.group_access(group_id, 'full').sort_by(&:login).each do |user|
          recipients_raw.push(user.email)
        end
      when %r{\Auserid_(\d+)\z}
        user = User.lookup(id: $1)
        if !user
          logger.warn "Can't find configured Trigger Email recipient User with ID '#{$1}'"
          next
        end
        recipients_raw.push(user.email)
      else
        logger.error "Unknown email notification recipient '#{recipient}'"
        next
      end
    end

    recipients_checked = []
    recipients_raw.each do |recipient_email|

      users = User.where(email: recipient_email)
      next if users.any? { |user| !trigger_based_notification?(user) }

      # send notifications only to email addresses
      next if recipient_email.blank?

      # check if address is valid
      begin
        Mail::AddressList.new(recipient_email).addresses.each do |address|
          recipient_email = address.address
          email_address_validation = EmailAddressValidation.new(recipient_email)
          break if recipient_email.present? && email_address_validation.valid?
        end
      rescue
        if recipient_email.present?
          if recipient_email !~ %r{^(.+?)<(.+?)@(.+?)>$}
            next # no usable format found
          end

          recipient_email = "#{$2}@#{$3}" # rubocop:disable Lint/OutOfRangeRegexpRef
        end
      end

      email_address_validation = EmailAddressValidation.new(recipient_email)
      next if !email_address_validation.valid?

      # do not send notification if system address
      next if EmailAddress.exists?(email: recipient_email.downcase)

      # do not sent notifications to this recipients
      send_no_auto_response_reg_exp = Setting.get('send_no_auto_response_reg_exp')
      begin
        next if recipient_email.match?(%r{#{send_no_auto_response_reg_exp}}i)
      rescue => e
        logger.error "Invalid regex '#{send_no_auto_response_reg_exp}' in setting send_no_auto_response_reg_exp"
        logger.error e
        next if recipient_email.match?(%r{(mailer-daemon|postmaster|abuse|root|noreply|noreply.+?|no-reply|no-reply.+?)@.+?}i)
      end

      # check if notification should be send because of customer emails
      if article.present? && article.preferences.fetch('is-auto-response', false) == true && article.from && article.from =~ %r{#{Regexp.quote(recipient_email)}}i
        logger.info "Send no trigger based notification to #{recipient_email} because of auto response tagged incoming email"
        next
      end

      # loop protection / check if maximal count of trigger mail has reached
      map = {
        10  => 10,
        30  => 15,
        60  => 25,
        180 => 50,
        600 => 100,
      }
      skip = false
      map.each do |minutes, count|
        already_sent = Ticket::Article.where(
          ticket_id: id,
          sender:    Ticket::Article::Sender.find_by(name: 'System'),
          type:      Ticket::Article::Type.find_by(name: 'email'),
        ).where('ticket_articles.created_at > ? AND ticket_articles.to LIKE ?', Time.zone.now - minutes.minutes, "%#{recipient_email.strip}%").count
        next if already_sent < count

        logger.info "Send no trigger based notification to #{recipient_email} because already sent #{count} for this ticket within last #{minutes} minutes (loop protection)"
        skip = true
        break
      end
      next if skip

      map = {
        10  => 30,
        30  => 60,
        60  => 120,
        180 => 240,
        600 => 360,
      }
      skip = false
      map.each do |minutes, count|
        already_sent = Ticket::Article.where(
          sender: Ticket::Article::Sender.find_by(name: 'System'),
          type:   Ticket::Article::Type.find_by(name: 'email'),
        ).where('ticket_articles.created_at > ? AND ticket_articles.to LIKE ?', Time.zone.now - minutes.minutes, "%#{recipient_email.strip}%").count
        next if already_sent < count

        logger.info "Send no trigger based notification to #{recipient_email} because already sent #{count} in total within last #{minutes} minutes (loop protection)"
        skip = true
        break
      end
      next if skip

      email = recipient_email.downcase.strip
      next if recipients_checked.include?(email)

      recipients_checked.push(email)
    end

    return if recipients_checked.blank?

    recipient_string = recipients_checked.join(', ')

    group_id = self.group_id
    return if !group_id

    email_address = Group.find(group_id).email_address
    if !email_address
      logger.info "Unable to send trigger based notification to #{recipient_string} because no email address is set for group '#{group.name}'"
      return
    end

    if !email_address.channel_id
      logger.info "Unable to send trigger based notification to #{recipient_string} because no channel is set for email address '#{email_address.email}' (id: #{email_address.id})"
      return
    end

    security = nil
    if Setting.get('smime_integration')
      sign       = value['sign'].present? && value['sign'] != 'no'
      encryption = value['encryption'].present? && value['encryption'] != 'no'

      security = SecureMailing::SMIME::NotificationOptions.process(
        from:       email_address,
        recipients: recipients_checked,
        perform:    {
          sign:    sign,
          encrypt: encryption,
        },
      )

      if sign && value['sign'] == 'discard' && !security[:sign][:success]
        logger.info "Unable to send trigger based notification to #{recipient_string} because of missing group #{group.name} email #{email_address.email} certificate for signing (discarding notification)."
        return
      end

      if encryption && value['encryption'] == 'discard' && !security[:encryption][:success]
        logger.info "Unable to send trigger based notification to #{recipient_string} because public certificate is not available for encryption (discarding notification)."
        return
      end
    end

    if Setting.get('pgp_integration') && (security.nil? || (!security[:encryption][:success] && !security[:sign][:success]))
      sign       = value['sign'].present? && value['sign'] != 'no'
      encryption = value['encryption'].present? && value['encryption'] != 'no'

      security = SecureMailing::PGP::NotificationOptions.process(
        from:       email_address,
        recipients: recipients_checked,
        perform:    {
          sign:    sign,
          encrypt: encryption,
        },
      )

      if sign && value['sign'] == 'discard' && !security[:sign][:success]
        logger.info "Unable to send trigger based notification to #{recipient_string} because of missing group #{group.name} email #{email_address.email} PGP key for signing (discarding notification)."
        return
      end

      if encryption && value['encryption'] == 'discard' && !security[:encryption][:success]
        logger.info "Unable to send trigger based notification to #{recipient_string} because public PGP keys are not available for encryption (discarding notification)."
        return
      end
    end

    objects = build_notification_template_objects(article)

    # get subject
    subject = NotificationFactory::Mailer.template(
      templateInline: value['subject'],
      objects:        objects,
      quote:          false,
    )
    subject = subject_build(subject)

    body = NotificationFactory::Mailer.template(
      templateInline: value['body'],
      objects:        objects,
      quote:          true,
    )

    (body, attachments_inline) = HtmlSanitizer.replace_inline_images(body, id)

    preferences                  = {}
    preferences[:perform_origin] = perform_origin
    if security.present?
      preferences[:security] = security
    end

    message = Ticket::Article.new(
      ticket_id:     id,
      to:            recipient_string,
      subject:       subject,
      content_type:  'text/html',
      body:          body,
      internal:      value['internal'] || false, # default to public if value was not set
      sender:        Ticket::Article::Sender.find_by(name: 'System'),
      type:          Ticket::Article::Type.find_by(name: 'email'),
      preferences:   preferences,
      updated_by_id: 1,
      created_by_id: 1,
    )
    message.history_change_source_attribute(performable, 'created')
    message.save!

    attachments_inline.each do |attachment|
      Store.create!(
        object:      'Ticket::Article',
        o_id:        message.id,
        data:        attachment[:data],
        filename:    attachment[:filename],
        preferences: attachment[:preferences],
      )
    end

    original_article = objects[:article]

    if ActiveModel::Type::Boolean.new.cast(value['include_attachments']) == true && original_article&.attachments.present?
      original_article.clone_attachments('Ticket::Article', message.id, only_attached_attachments: true)
    end

    if original_article&.should_clone_inline_attachments? # rubocop:disable Style/GuardClause
      original_article.clone_attachments('Ticket::Article', message.id, only_inline_attachments: true)
      original_article.should_clone_inline_attachments = false # cancel the temporary flag after cloning
    end
  end

  def sms_recipients_by_type(recipient_type, article)
    case recipient_type
    when 'article_last_sender'
      return nil if article.blank?

      if article.origin_by_id
        article.origin_by_id
      elsif article.created_by_id
        article.created_by_id
      end
    when 'ticket_customer'
      customer_id
    when 'ticket_owner'
      owner_id
    when 'ticket_agents'
      User.group_access(group_id, 'full').sort_by(&:login)
    when %r{\Auserid_(\d+)\z}
      return $1 if User.exists?($1)

      logger.warn "Can't find configured Trigger SMS recipient User with ID '#{$1}'"
      nil
    else
      logger.error "Unknown sms notification recipient '#{recipient}'"
      nil
    end
  end

  def build_sms_recipients_list(value, article)
    Array(value['recipient'])
      .each_with_object([]) { |recipient_type, sum| sum.concat(Array(sms_recipients_by_type(recipient_type, article))) }
      .map { |user_or_id| user_or_id.is_a?(User) ? user_or_id : User.lookup(id: user_or_id) }
      .uniq(&:id)
      .select { |user| user.mobile.present? }
  end

  def send_sms_notification(value, article, perform_origin, performable)
    sms_recipients = build_sms_recipients_list(value, article)

    if sms_recipients.blank?
      logger.debug "No SMS recipients found for Ticket# #{number}"
      return
    end

    sms_recipients_to = sms_recipients
                        .map { |recipient| "#{recipient.fullname} (#{recipient.mobile})" }
                        .join(', ')

    channel = Channel.find_by(area: 'Sms::Notification')
    if !channel.active?
      # write info message since we have an active trigger
      logger.info "Found possible SMS recipient(s) (#{sms_recipients_to}) for Ticket# #{number} but SMS channel is not active."
      return
    end

    objects = build_notification_template_objects(article)
    body = NotificationFactory::Renderer.new(
      objects:  objects,
      template: value['body'],
      escape:   false
    ).render.html2text.tr(' ', ' ') # convert non-breaking space to simple space

    # attributes content_type is not needed for SMS
    article = Ticket::Article.new(
      ticket_id:     id,
      subject:       'SMS notification',
      to:            sms_recipients_to,
      body:          body,
      internal:      value['internal'] || false, # default to public if value was not set
      sender:        Ticket::Article::Sender.find_by(name: 'System'),
      type:          Ticket::Article::Type.find_by(name: 'sms'),
      preferences:   {
        perform_origin: perform_origin,
        sms_recipients: sms_recipients.map(&:mobile),
        channel_id:     channel.id,
      },
      updated_by_id: 1,
      created_by_id: 1,
    )
    article.history_change_source_attribute(performable, 'created')
    article.save!
  end

  def trigger_based_notification?(user)
    blocked_in_days = trigger_based_notification_blocked_in_days(user)
    return true if blocked_in_days.zero?

    logger.info "Send no trigger based notification to #{user.email} because email is marked as mail_delivery_failed for #{blocked_in_days} day(s)"
    false
  end

  def trigger_based_notification_blocked_in_days(user)
    return 0 if !user.preferences[:mail_delivery_failed]
    return 0 if user.preferences[:mail_delivery_failed_data].blank?

    # blocked for 60 full days; see #4459
    remaining_days = (user.preferences[:mail_delivery_failed_data].to_date - Time.zone.now.to_date).to_i + 61
    return remaining_days if remaining_days.positive?

    # cleanup user preferences
    user.preferences[:mail_delivery_failed] = false
    user.preferences[:mail_delivery_failed_data] = nil
    user.save!
    0
  end

end
