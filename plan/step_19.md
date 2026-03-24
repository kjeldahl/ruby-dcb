# Step 19: Mutation Testing with Mutant

## Goal

Add [mutant](https://github.com/mbj/mutant) for mutation testing. Mutant
systematically modifies source code and verifies tests catch each change.
Alive mutations (undetected changes) reveal missing or weak tests.

## Setup

### 1. Add dependency

In `dcb_event_store.gemspec`:

```ruby
s.add_development_dependency "mutant-minitest", "~> 0.12"
```

Then `bundle install`.

### 2. Require mutant coverage in test helper

Add to `test/test_helper.rb` **after** `require "minitest/autorun"`:

```ruby
require "mutant/minitest/coverage"
```

### 3. Add `.cover` declarations to test classes

Each test class declares which subjects it covers. Mutant uses these to
know which mutations a test is expected to kill.

**Patterns:**
- `cover "DcbEventStore::Foo*"` — wildcard, covers all methods on `Foo`
- `cover "DcbEventStore::Foo#bar"` — specific instance method
- `cover "DcbEventStore::Foo.bar"` — specific class method

**Mapping:**

| Test file | `.cover` declaration |
|-----------|---------------------|
| `test/unit/test_event.rb` | `cover "DcbEventStore::Event*"` |
| `test/unit/test_query.rb` | `cover "DcbEventStore::Query*"`, `cover "DcbEventStore::QueryItem*"` |
| `test/unit/test_projection.rb` | `cover "DcbEventStore::Projection*"` |
| `test/unit/test_upcaster.rb` | `cover "DcbEventStore::Upcaster*"` |
| `test/unit/test_client.rb` | `cover "DcbEventStore::Client*"` |
| `test/integration/test_store_append.rb` | `cover "DcbEventStore::Store#append"` |
| `test/integration/test_store_read.rb` | `cover "DcbEventStore::Store#read"` |
| `test/integration/test_read_from.rb` | `cover "DcbEventStore::Store#read_from"` |
| `test/integration/test_subscribe.rb` | `cover "DcbEventStore::Store#subscribe"` |
| `test/integration/test_client.rb` | `cover "DcbEventStore::Client*"` |
| `test/integration/test_decision_model.rb` | `cover "DcbEventStore::DecisionModel*"` |
| `test/integration/test_upcaster_integration.rb` | `cover "DcbEventStore::Upcaster*"` |

Example in a test file:

```ruby
class TestEvent < Minitest::Test
  cover "DcbEventStore::Event*"

  def test_creates_with_defaults
    # ...
  end
end
```

### 4. Configuration file (optional)

Create `.mutant.yml` at project root for repeatable runs:

```yaml
integration: minitest
requires:
  - ./lib/dcb_event_store
  - ./test/test_helper
  - ./test/unit/test_event
  - ./test/unit/test_query
  - ./test/unit/test_projection
  - ./test/unit/test_upcaster
  - ./test/unit/test_client
  - ./test/integration/test_store_append
  - ./test/integration/test_store_read
  - ./test/integration/test_read_from
  - ./test/integration/test_subscribe
  - ./test/integration/test_client
  - ./test/integration/test_decision_model
  - ./test/integration/test_upcaster_integration
usage: opensource
matcher:
  subjects:
    - DcbEventStore::Event*
    - DcbEventStore::Query*
    - DcbEventStore::QueryItem*
    - DcbEventStore::AppendCondition*
    - DcbEventStore::Projection*
    - DcbEventStore::DecisionModel*
    - DcbEventStore::Upcaster*
    - DcbEventStore::Client*
    - DcbEventStore::Store*
```

Note: `Schema`, `ConditionNotMet`, and `Version` are excluded — they're
infrastructure/trivial classes where mutation testing adds little value.

## Running

```bash
# Full run (all subjects in .mutant.yml)
bundle exec mutant run

# Single class
bundle exec mutant run --use minitest \
  --require ./lib/dcb_event_store \
  --require ./test/test_helper \
  'DcbEventStore::Event*'

# Single method
bundle exec mutant run --use minitest \
  --require ./lib/dcb_event_store \
  --require ./test/test_helper \
  'DcbEventStore::Store#append'

# Incremental (only changed code since last run)
bundle exec mutant run --since main
```

### Rake task (optional)

Add to `Rakefile`:

```ruby
desc "Run mutation tests"
task :mutant do
  sh "bundle exec mutant run"
end
```

## Interpreting results

- **Killed** — test suite detected the mutation (good)
- **Alive** — mutation went undetected; either:
  - Add a test that would catch it, or
  - Accept it if the mutation is semantically equivalent
- **Timeout** — mutation caused infinite loop (counts as killed)

Target: 100% kill rate on core logic (`Store#append`, `Projection`, `DecisionModel`).
Alive mutations on `Data.define` accessors or trivial delegators are acceptable.

## Scope exclusions

Skip mutation testing for:
- `Schema` — DDL strings, not behavioral logic
- `ConditionNotMet` — trivial exception class
- `Version` — constant
- `test/` and `examples/` — not production code
- Concurrency tests — mutant runs mutations sequentially; race-dependent
  tests are not suitable subjects

## Files changed

- `dcb_event_store.gemspec` — add `mutant-minitest` dev dependency
- `test/test_helper.rb` — require `mutant/minitest/coverage`
- `test/unit/test_event.rb` — add `cover` declaration
- `test/unit/test_query.rb` — add `cover` declarations
- `test/unit/test_projection.rb` — add `cover` declaration
- `test/unit/test_upcaster.rb` — add `cover` declaration
- `test/unit/test_client.rb` — add `cover` declaration
- `test/integration/test_store_append.rb` — add `cover` declaration
- `test/integration/test_store_read.rb` — add `cover` declaration
- `test/integration/test_read_from.rb` — add `cover` declaration
- `test/integration/test_subscribe.rb` — add `cover` declaration
- `test/integration/test_client.rb` — add `cover` declaration
- `test/integration/test_decision_model.rb` — add `cover` declaration
- `test/integration/test_upcaster_integration.rb` — add `cover` declaration
- `.mutant.yml` — config file (new)
- `Rakefile` — optional `mutant` task
- `CLAUDE.md` — add mutant to Stack, add mutation testing commands to Running tests

### CLAUDE.md updates

**Stack** — append `mutant` for mutation testing:

```
- Mutant (`mutant-minitest`) for mutation testing
```

**Running tests** — add mutation testing commands:

```sh
bundle exec mutant run                            # mutation testing (all subjects)
bundle exec mutant run 'DcbEventStore::Store#append'  # single method
```

## Done when

- `bundle exec mutant run` completes without config errors
- Alive mutations reviewed and either killed or accepted
- `bundle exec rake` still green (mutant is additive, no test changes)
- `CLAUDE.md` documents mutant in Stack and Running tests sections
