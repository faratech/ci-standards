#!/usr/bin/env ruby

require "psych"

workflow_paths = Dir.glob(".github/workflows/**/*.{yml,yaml}").sort
workflow_paths.reject! { |path| path.end_with?("actions-policy.yml") }

findings = []
parse_errors = []
tiers = {}

begin
  policy_path = ".github/ci-policy.yml"
  if File.file?(policy_path)
    policy = Psych.safe_load(File.read(policy_path), aliases: true) || {}
    unless policy.is_a?(Hash) && policy["version"] == 1 && policy["workflows"].is_a?(Hash)
      findings << [policy_path, "ci-policy.yml must contain version: 1 and a workflows mapping"]
    else
      policy["workflows"].each do |path, tier|
        value = tier.is_a?(Hash) ? tier["tier"] : tier
        unless %w[fast deep release event].include?(value)
          findings << [policy_path, "workflow '#{path}' has unknown tier '#{value}'"]
        end
        tiers[path] = value
      end
    end
  end
rescue Psych::Exception => e
  parse_errors << ".github/ci-policy.yml: #{e.message.lines.first.strip}"
end

def key(data, name)
  return data[name] if data.is_a?(Hash) && data.key?(name)
  return data[true] if name == "on" && data.is_a?(Hash) && data.key?(true)
  nil
end

def event_hash(events)
  return {} unless events.is_a?(Hash)
  events
end

def event_names(events)
  return events.keys if events.is_a?(Hash)
  return events if events.is_a?(Array)
  events.nil? ? [] : [events.to_s]
end

workflow_paths.each do |path|
  begin
    data = Psych.safe_load(File.read(path), aliases: true) || {}
  rescue Psych::Exception => e
    parse_errors << "#{path}: #{e.message.lines.first.strip}"
    next
  end

  unless data.is_a?(Hash)
    findings << [path, "workflow root is not a mapping"]
    next
  end

  workflow_name = File.basename(path)
  release_like = workflow_name.match?(/release|publish|sign/i)
  tier = tiers[path] || if release_like
    "release"
  elsif workflow_name.match?(/codeql|fuzz|miri|pty|interop|validation|audit/i)
    "deep"
  elsif workflow_name.match?(/ci|build|test/i)
    "fast"
  else
    "event"
  end
  findings << [path, "missing top-level concurrency"] unless data.key?("concurrency")

  raw_events = key(data, "on")
  events = event_hash(raw_events)
  names = event_names(raw_events)
  if tier == "deep" && (names.include?("push") || names.include?("pull_request"))
    findings << [path, "deep workflow is triggered by push/pull_request"]
  end
  if events.key?("push") && events.key?("pull_request")
    push = events["push"]
    pull = events["pull_request"]
    push_paths = push.is_a?(Hash) && (push.key?("paths") || push.key?("paths-ignore"))
    pull_paths = pull.is_a?(Hash) && (pull.key?("paths") || pull.key?("paths-ignore"))
    findings << [path, "push and pull_request both lack path filtering"] unless push_paths || pull_paths
  end

  jobs = data["jobs"]
  next unless jobs.is_a?(Hash)

  jobs.each do |job_name, job|
    next unless job.is_a?(Hash)
    if job.key?("uses")
      next
    end

    findings << [path, "job '#{job_name}' has no timeout-minutes"] unless job.key?("timeout-minutes")

    strategy = job["strategy"]
    if strategy.is_a?(Hash) && strategy["matrix"] && !strategy.key?("max-parallel")
      findings << [path, "matrix job '#{job_name}' has no max-parallel"]
    end

    runner = job["runs-on"].to_s
    if runner.include?("self-hosted") && !job.key?("timeout-minutes")
      findings << [path, "self-hosted job '#{job_name}' has no post-allocation timeout"]
    end
  end

  concurrency = data["concurrency"]
  if concurrency.is_a?(Hash) && concurrency["cancel-in-progress"] == false && !release_like
    findings << [path, "cancel-in-progress is false on a non-release workflow"]
  end
end

parse_errors.each { |finding| puts "::warning title=Workflow parser compatibility::#{finding}" }
findings.each { |path, message| puts "::warning file=#{path},title=Actions cost policy::#{message}" }

puts "Actions policy scanned #{workflow_paths.length} workflow(s): #{findings.length} finding(s), #{parse_errors.length} parse error(s)."

if ENV.fetch("POLICY_STRICT", "false").downcase == "true" && (!findings.empty? || !parse_errors.empty?)
  abort "Actions policy failed in strict mode."
end
