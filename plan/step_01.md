# Step 1: Gem Skeleton

## Goal
Set up the gem project structure so `bundle install` works and `bundle exec rake` runs (even with no tests yet).

## Files to Create
- `Gemfile` -- source rubygems, gemspec
- `dcb_event_store.gemspec` -- name `dcb_event_store`, Ruby >= 3.3, runtime dep `pg`, dev deps `minitest` + `concurrent-ruby` + `rake`
- `Rakefile` -- default task runs minitest, test dir is `test`
- `lib/dcb_event_store.rb` -- module `DcbEventStore`, requires all subfiles
- `lib/dcb_event_store/version.rb` -- `DcbEventStore::VERSION = "0.1.0"`

## Done When
- `bundle install` succeeds
- `bundle exec rake` runs without error (0 tests, 0 failures)
- `ruby -e "require 'dcb_event_store'; puts DcbEventStore::VERSION"` prints `0.1.0`
