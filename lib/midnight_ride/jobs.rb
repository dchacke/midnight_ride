require "active_job"

module MidnightRide
  # Alerts about a new error in Solid Errors, or a resolved one that came
  # back (see Railtie). It's enqueued with a short wait, since the error is
  # saved before the occurrence with its backtrace.
  class AlertJob < ActiveJob::Base
    def perform error_id, reopened: false
      error = SolidErrors::Error.find_by(id: error_id)
      return unless error

      MidnightRide.alert(error, reopened:)
    rescue => e
      # Reporting it would make another error to alert about, and so on.
      MidnightRide.logger.error("MidnightRide::AlertJob failed for error #{error_id}: #{e.class}: #{e.message}")
    end
  end

  # Once a day, alerts again about each unresolved error that still happened
  # in the last day, with how often, and starts another session for it.
  # Errors new in the last day were alerted about already.
  class RemindersJob < ActiveJob::Base
    def perform
      since = 1.day.ago
      counts = SolidErrors::Occurrence.where(created_at: since..).group(:error_id).count

      SolidErrors::Error.unresolved.where(id: counts.keys, created_at: ...since).find_each do |error|
        MidnightRide.alert(error, still_happening: counts[error.id])
      rescue => e
        MidnightRide.logger.error("MidnightRide::RemindersJob failed for error #{error.id}: #{e.class}: #{e.message}")
      end
    end
  end

  # Once a day, resolves the errors that haven't happened for a while
  # (MidnightRide.quiet_for): whatever caused them is probably fixed, often
  # without a commit naming them. If one comes back, it alerts again.
  class ResolveQuietErrorsJob < ActiveJob::Base
    def perform
      recent = SolidErrors::Occurrence.where(created_at: MidnightRide.quiet_for.ago..).select(:error_id)
      SolidErrors::Error.unresolved.where.not(id: recent).update_all(resolved_at: Time.current)
    end
  end

  def self.alert error, **options
    Alert.new(
      id: error.id,
      exception_class: error.exception_class,
      message: error.message,
      backtrace: error.occurrences.order(:id).last&.backtrace,
      **options
    ).deliver
  end
end
