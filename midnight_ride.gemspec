require_relative "lib/midnight_ride/version"

Gem::Specification.new do |spec|
  spec.name = "midnight_ride"
  spec.version = MidnightRide::VERSION
  spec.authors = ["Dennis Hackethal"]
  spec.summary = "Alerts you on Telegram when a Rails app errors in production and starts a Claude Code session to fix it."
  spec.description = "Builds on Solid Errors: alerts about new errors, resolved ones that come back, and unresolved ones still happening, and starts a Claude Code session for each through a routine's API trigger."
  spec.homepage = "https://github.com/dchacke/midnight_ride"
  # The adjusted MIT license in LICENSE
  spec.license = "Nonstandard"
  spec.required_ruby_version = ">= 3.4"

  spec.files = Dir["lib/**/*", "LICENSE", "README.md"]

  spec.add_dependency "activejob", ">= 7.1"
  spec.add_dependency "activesupport", ">= 7.1"
  spec.add_dependency "railties", ">= 7.1"
end
