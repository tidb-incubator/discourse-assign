# frozen_string_literal: true

module Jobs
  class EnqueueReminders < ::Jobs::Scheduled
    every 1.day

    def execute(_args)
      return if skip_enqueue?
      user_ids.each { |id| Jobs.enqueue(:remind_user, user_id: id) }
    end

    private

    def skip_enqueue?
      SiteSetting.remind_assigns_frequency.nil? || !SiteSetting.assign_enabled? || SiteSetting.assign_allowed_on_groups.blank?
    end

    def allowed_group_ids
      Group.assign_allowed_groups.pluck(:id).join(',')
    end

    def user_ids
      global_frequency = SiteSetting.remind_assigns_frequency
      frequency = ActiveRecord::Base.sanitize_sql("COALESCE(user_frequency.value, '#{global_frequency}')::INT")

      DB.query_single(<<~SQL
        SELECT topic_custom_fields.value
        FROM topic_custom_fields

        LEFT OUTER JOIN user_custom_fields AS last_reminder
        ON CAST(topic_custom_fields.value AS SIGNED) = last_reminder.user_id
        AND last_reminder.name = '#{PendingAssignsReminder::REMINDED_AT}'

        LEFT OUTER JOIN user_custom_fields AS user_frequency
        ON CAST(topic_custom_fields.value AS SIGNED) = user_frequency.user_id
        AND user_frequency.name = '#{PendingAssignsReminder::REMINDERS_FREQUENCY}'

        INNER JOIN group_users ON CAST(topic_custom_fields.value AS SIGNED) = group_users.user_id
        INNER JOIN topics ON topics.id = topic_custom_fields.topic_id AND (topics.deleted_at IS NULL)

        WHERE group_users.group_id IN (#{allowed_group_ids})
        AND #{frequency} > 0
        AND (
          last_reminder.value IS NULL OR
          cast(last_reminder.value as datetime) <= date_add(CURRENT_TIMESTAMP, interval (-1 * #{frequency}) minute)
        )
        AND cast(topic_custom_fields.updated_at as datetime) <= date_add(CURRENT_TIMESTAMP, interval (-1 * #{frequency}) minute)
        AND topic_custom_fields.name = '#{TopicAssigner::ASSIGNED_TO_ID}'

        GROUP BY topic_custom_fields.value
        HAVING COUNT(topic_custom_fields.value) > 1
      SQL
      )
    end
  end
end
