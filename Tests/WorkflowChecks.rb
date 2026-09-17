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
check(release.fetch('on', release[true]) == { 'push' => { 'branches' => ['main'] }, 'workflow_dispatch' => nil }, 'Only main pushes and manual Homebrew updates may trigger the workflow')
check(release['jobs']['release']['if'] == "github.event_name == 'push' && github.ref == 'refs/heads/main'", 'App releases must run only for main pushes')
check(release['concurrency'] == { 'group' => 'release', 'cancel-in-progress' => false, 'queue' => 'max' }, 'Releases must queue together without cancelling earlier runs')
homebrew = release['jobs']['homebrew']
tap_checkout = homebrew['steps'].find { |step| step.dig('with', 'repository') == 'tuckerritti/homebrew-tap' }
check(tap_checkout, 'Homebrew must check out the fixed tap repository')
check(tap_checkout['with'].slice('path', 'ref', 'ssh-key', 'persist-credentials') == {
  'path' => 'homebrew-tap', 'ref' => 'main',
  'ssh-key' => '${{ secrets.HOMEBREW_TAP_SSH_KEY }}', 'persist-credentials' => true
}, 'Only the tap checkout may retain its dedicated SSH key for pushing')
workflows.each do |workflow|
  check(workflow['permissions'] == { 'contents' => 'read' }, 'Default token permissions must be read-only')
  workflow['jobs'].each_value do |job|
    check(job['runs-on'] == 'macos-15', 'Use the verified hosted macOS runner')
    job['steps'].each do |step|
      if step['uses']
        check(step['uses'].match?(/\Aactions\/checkout@[a-f0-9]{40}\z/), 'Checkout must be the only action and pinned by SHA')
        unless job.equal?(homebrew) && step.equal?(tap_checkout)
          check(step.dig('with', 'persist-credentials') == false, 'Source checkout must not persist Git credentials')
        end
      end
      next unless step['run']
      check(!step['run'].include?('${{'), 'Pass GitHub context through environment variables')
      _, error, status = Open3.capture3({ 'BASH_ENV' => nil }, '/bin/bash', '--noprofile', '--norc', '-n', stdin_data: step['run'])
      check(status.success?, "Invalid shell syntax: #{error}")
    end
  end
end
steps = release['jobs']['release']['steps']
source = steps.find { |step| step['id'] == 'source' }['run']
tag = steps.find { |step| step['id'] == 'tag' }['run']
publish = steps.find { |step| step['id'] == 'publish' }['run']
credentials_index = steps.index { |step| step['id'] == 'credentials' }
tag_index = steps.index { |step| step['id'] == 'tag' }
check(steps.index { |step| step['id'] == 'checks' } < tag_index && tag_index < credentials_index, 'Checks must pass before tagging and loading signing credentials')
build = steps.find { |step| step['name'] == 'Build signed and notarized DMG' }
check(build.dig('env', 'RELEASE_BUILD_NUMBER') == '${{ github.run_number }}', 'The release build number must come from the workflow run number')
check(!release['jobs']['release']['env'].key?('RELEASE_BUILD_NUMBER'), 'Build metadata must be scoped to the real build step')
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
      [[ $# -eq 1 && $1 == -version ]] || exit 2
      printf 'Xcode 26.3\nBuild version 17C529\n'
    elif [[ $1 == api ]]; then
      if [[ " $* " == *' --method POST '* ]]; then
        printf '%s\n' "$@" >"$RUNNER_TEMP/tag-request"
      elif [[ " $* " == *'/commits/'* ]]; then
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
  previous = git.call('rev-parse', 'HEAD')
  git.call('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-q', '--allow-empty', '-m', 'Release')
  commit = git.call('rev-parse', 'HEAD')
  git.call('update-ref', 'refs/remotes/origin/main', commit)
  github_env = File.join(temporary, 'github-env')
  tag_request = File.join(temporary, 'tag-request')
  environment = {
    'PATH' => "#{bin}:#{ENV.fetch('PATH')}", 'BASH_ENV' => nil, 'RUNNER_TEMP' => temporary, 'RELEASE_DIR' => artifacts,
    'GITHUB_SHA' => commit, 'GITHUB_REF' => 'refs/heads/main', 'GITHUB_REPOSITORY' => 'mock/repo',
    'GITHUB_ENV' => github_env, 'RELEASE_TAG' => 'v1.0', 'RELEASE_BUILD_NUMBER' => nil, 'MOCK_MODE' => 'accepted'
  }
  run = lambda do |script, overrides = {}|
    # Actions uses Apple's Bash; Homebrew Bash has different errexit behavior for [[ ... && ... ]].
    Open3.capture3(environment.merge(overrides), '/bin/bash', '--noprofile', '--norc', '-e', '-o', 'pipefail', '-c', script, chdir: directory)
  end
  output, error, status = run.call(source)
  check(status.success?, "Valid main source was rejected: #{output}#{error}")
  [{ 'GITHUB_REF' => 'refs/heads/feature' }, { 'GITHUB_REF' => 'refs/heads/main$(touch injected)' },
   { 'GITHUB_SHA' => previous }].each do |overrides|
    check(!run.call(source, overrides).last.success?, "Unsafe release source accepted: #{overrides}")
  end
  check(!File.exist?(File.join(directory, 'injected')), 'Ref text was evaluated as shell code')
  git.call('update-ref', '-d', 'refs/remotes/origin/main')
  check(!run.call(source).last.success?, 'A source without main ancestry was accepted')

  check_tag = lambda do |expected, create|
    FileUtils.rm_f([github_env, tag_request])
    output, error, status = run.call(tag)
    check(status.success?, "Valid automatic tag was rejected: #{output}#{error}")
    check(File.read(github_env) == "RELEASE_TAG=#{expected}\n", 'The wrong release version was selected')
    check(File.exist?(tag_request) == create, 'Tag creation/reuse was incorrect')
    if create
      arguments = File.readlines(tag_request, chomp: true)
      check(arguments.include?("ref=refs/tags/#{expected}") && arguments.include?("sha=#{commit}"), 'The tag must name the exact release commit')
    end
  end
  check_tag.call('v0.0.1', true)
  git.call('tag', 'v1.0', previous)
  check_tag.call('v1.0.1', true)
  %w[v1.0.9 v1.0.10 v99.0.0-rc.1].each { |name| git.call('tag', name, previous) }
  check_tag.call('v1.0.11', true)
  git.call('tag', 'v1.0.11', commit)
  check_tag.call('v1.0.11', false)
  FileUtils.rm_f([github_env, tag_request])
  check(!run.call(tag, 'GITHUB_SHA' => previous).last.success?, 'An old rerun after a newer tagged commit was accepted')
  check(!File.exist?(github_env) && !File.exist?(tag_request), 'An old rerun created a release tag')
  git.call('tag', '-d', 'v1.0.11', 'v1.0.10', 'v1.0.9')
  %w[moved duplicate].each do |mode|
    FileUtils.rm_f(github_env)
    # Reuse the existing v1.0 tag so the duplicate mock matches that release.
    check(!run.call(tag, 'MOCK_MODE' => mode, 'GITHUB_SHA' => previous).last.success?, "Unsafe release tag accepted: #{mode}")
    check(!File.exist?(github_env), 'An unsafe tag was passed to the build')
  end

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
puts 'Workflow checks passed: YAML/shell syntax, credential boundaries, main source, automatic patch tags, and draft publication gates.'
