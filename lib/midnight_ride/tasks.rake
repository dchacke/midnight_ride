# For apps that schedule the daily jobs with cron rather than Solid Queue's
# recurring tasks
namespace :midnight_ride do
  desc "Alert again about unresolved errors that still happened in the last day"
  task reminders: :environment do
    MidnightRide::RemindersJob.perform_now
  end

  desc "Resolve errors that haven't happened for a while"
  task resolve_quiet: :environment do
    MidnightRide::ResolveQuietErrorsJob.perform_now
  end
end
