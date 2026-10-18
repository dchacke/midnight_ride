require "midnight_ride/jobs"

module MidnightRide
  # Alerts about new errors in Solid Errors, and resolved ones that came
  # back, when enabled (in production, by default) and Solid Errors is
  # there.
  class Railtie < Rails::Railtie
    config.to_prepare do
      next unless MidnightRide.enabled? && defined?(SolidErrors::Error)

      SolidErrors::Error.after_create_commit do
        MidnightRide::AlertJob.set(wait: 10.seconds).perform_later(id)
      end

      SolidErrors::Error.after_update_commit if: -> { saved_change_to_resolved_at? && resolved_at.nil? } do
        MidnightRide::AlertJob.set(wait: 10.seconds).perform_later(id, reopened: true)
      end
    end

    rake_tasks do
      load "midnight_ride/tasks.rake"
    end
  end
end
