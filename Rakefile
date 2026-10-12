require "rake/testtask"
require "etc"

Rake::TestTask.new do |t|
  t.test_files = FileList["test/**/test_*.rb"]
  t.warning = false
end

desc "Run mutation tests"
task :mutant do
  sh "bundle exec mutant run --jobs #{mutant_jobs}"
end

# Leave the last two cores free: mutant runs the suite per kill job, each worker
# against its own database (see test/support/mutant_hooks.rb), and the headroom
# keeps the box responsive.
def mutant_jobs
  cpus =
    if Etc.respond_to?(:nproc)
      Etc.nproc
    else
      `nproc`.strip.to_i.nonzero? || 1
    end
  [cpus - 2, 1].max
end

task default: :test
