#!/usr/bin/env ruby
require 'yaml'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'open3'

def check(value, message)
  raise message unless value
end

root = File.expand_path('..', __dir__)
workflows = %w[ci release].map do |name|
  YAML.safe_load(File.read(File.join(root, '.github', 'workflows', "#{name}.yml")))
end
ci, release = workflows
check(!ci.to_s.include?('secrets.'), 'CI must not reference signing secrets')
check(release.fetch('on', release[true]) == { 'push' => { 'tags' => ['v*'] } }, 'Release must run only for pushed tags')
check(release['concurrency']['cancel-in-progress'] == false, 'Releases must not cancel each other')
workflows.each do |workflow|
  check(workflow['permissions'] == { 'contents' => 'read' }, 'Default token permissions must be read-only')
  workflow['jobs'].each_value do |job|
    check(job['runs-on'] == 'macos-15', 'Use the verified hosted macOS runner')
    job['steps'].each do |step|
      if step['uses']
        check(step['uses'].match?(/\Aactions\/checkout@[a-f0-9]{40}\z/), 'Checkout must be the only action and pinned by SHA')
        check(step.dig('with', 'persist-credentials') == false, 'Checkout must not persist Git credentials')
      end
      next unless step['run']
      check(!step['run'].include?('${{'), 'Pass GitHub context through environment variables')
      _, error, status = Open3.capture3('bash', '-n', stdin_data: step['run'])
      check(status.success?, "Invalid shell syntax: #{error}")
    end
  end
end
steps = release['jobs']['release']['steps']
source = steps.find { |step| step['id'] == 'source' }['run']
publish = steps.find { |step| step['id'] == 'publish' }['run']
credentials_index = steps.index { |step| step['id'] == 'credentials' }
check(steps.index { |step| step['id'] == 'checks' } < credentials_index, 'Checks must run before signing credentials are loaded')
check(steps.last['if'] == 'always()' && steps.last['run'].include?('security delete-keychain'), 'Keychain cleanup must always run')
steps.each_with_index do |step, index|
  check(index == credentials_index || !step.to_s.include?('secrets.'), 'Signing secrets must be scoped to their installation step')
end

Dir.mktmpdir('ai-usage-workflow-checks') do |directory|
  bin = File.join(directory, 'bin')
  temporary = File.join(directory, 'temp')
  artifacts = File.join(directory, 'artifacts')
  FileUtils.mkdir_p([bin, temporary, artifacts])
  mock = <<~'SH'
    #!/bin/bash
    set -euo pipefail
    if [[ ${0##*/} == xcodebuild ]]; then
      if [[ $1 == -version ]]; then
        printf 'Xcode 26.3\nBuild version 17C529\n'
      else
        printf '[{"target":"AIUsage","buildSettings":{"MARKETING_VERSION":"1.0"}}]\n'
      fi
    elif [[ $1 == api ]]; then
      if [[ " $* " == *'/commits/'* ]]; then
        if [[ $MOCK_MODE == moved || ($MOCK_MODE == moved_after_draft && -f "$RUNNER_TEMP/draft") ]]; then
          printf 'wrong-commit\n'
        else
          printf '%s\n' "$GITHUB_SHA"
        fi
      elif [[ $MOCK_MODE == duplicate ]]; then
        printf 'v1.0\n'
      fi
    elif [[ $1 == release && $2 == create ]]; then
      [[ " $* " == *' --draft '* && " $* " == *' --verify-tag '* ]]
      touch "$RUNNER_TEMP/draft"
    elif [[ $1 == release && $2 == view ]]; then
      if [[ $MOCK_MODE == partial ]]; then
        printf '{"isDraft":true,"assets":[{"name":"AI-Usage-1.0-1.dmg"}]}\n'
      else
        printf '{"isDraft":true,"assets":[{"name":"AI-Usage-1.0-1.dmg"},{"name":"AI-Usage-1.0-1.dmg.sha256"}]}\n'
      fi
    elif [[ $1 == release && $2 == edit ]]; then
      touch "$RUNNER_TEMP/published"
    else
      exit 2
    fi
  SH
  File.write(File.join(bin, 'mock'), mock)
  File.chmod(0o755, File.join(bin, 'mock'))
  %w[xcodebuild gh].each { |name| File.symlink('mock', File.join(bin, name)) }
  git = lambda do |*arguments|
    output, error, status = Open3.capture3('git', *arguments, chdir: directory)
    check(status.success?, "Git fixture failed: #{error}")
    output.strip
  end
  git.call('init', '-q', '-b', 'main')
  git.call('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-q', '--allow-empty', '-m', 'Fixture')
  commit = git.call('rev-parse', 'HEAD')
  git.call('update-ref', 'refs/remotes/origin/main', commit)
  %w[v1.0 v2.0].each { |tag| git.call('tag', tag) }
  environment = {
    'PATH' => "#{bin}:#{ENV.fetch('PATH')}", 'RUNNER_TEMP' => temporary, 'RELEASE_DIR' => artifacts,
    'GITHUB_SHA' => commit, 'GITHUB_REF_TYPE' => 'tag', 'GITHUB_REPOSITORY' => 'mock/repo',
    'RELEASE_TAG' => 'v1.0', 'MOCK_MODE' => 'accepted'
  }
  run = lambda do |script, overrides = {}|
    Open3.capture3(environment.merge(overrides), 'bash', '-e', '-o', 'pipefail', '-c', script, chdir: directory)
  end
  output, error, status = run.call(source)
  check(status.success?, "Valid tag was rejected: #{output}#{error}")
  [{ 'RELEASE_TAG' => 'v2.0' }, { 'RELEASE_TAG' => 'v1.0$(touch injected)' },
   { 'GITHUB_REF_TYPE' => 'branch' }, { 'MOCK_MODE' => 'moved' }, { 'MOCK_MODE' => 'duplicate' }].each do |overrides|
    check(!run.call(source, overrides).last.success?, "Unsafe release source accepted: #{overrides}")
  end
  check(!File.exist?(File.join(directory, 'injected')), 'Ref text was evaluated as shell code')
  git.call('update-ref', '-d', 'refs/remotes/origin/main')
  check(!run.call(source).last.success?, 'A source without main ancestry was accepted')

  dmg = File.join(artifacts, 'AI-Usage-1.0-1.dmg')
  File.write(dmg, 'mock notarized artifact')
  checksum, = Open3.capture3('shasum', '-a', '256', File.basename(dmg), chdir: artifacts)
  File.write("#{dmg}.sha256", checksum)
  %w[accepted partial moved_after_draft].each do |mode|
    FileUtils.rm_f([File.join(temporary, 'draft'), File.join(temporary, 'published')])
    output, error, status = run.call(publish, 'MOCK_MODE' => mode)
    expected = mode == 'accepted'
    check(status.success? == expected, "Wrong publication result for #{mode}: #{output}#{error}")
    check(File.exist?(File.join(temporary, 'published')) == expected, 'An incomplete or moved-tag release was published')
  end
end
puts 'Workflow checks passed: YAML/shell syntax, credential boundaries, tag/version/main checks, and draft publication gates.'
