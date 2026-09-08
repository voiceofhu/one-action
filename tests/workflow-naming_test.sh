#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ruby -ryaml -e '
  root = ARGV.fetch(0)
  files = Dir.glob("#{root}/.github/workflows/*.{yml,yaml}")
  files.each do |file|
    name = File.basename(file)
    document = YAML.safe_load(File.read(file), aliases: true)
    events = document.fetch("on")
    reusable = events.key?("workflow_call")
    pattern = reusable ? /\Areusable-[a-z0-9]+(?:-[a-z0-9]+)+\.yml\z/ :
      /\A(?!one-)[a-z][a-z0-9]*-(?:server|web|app|runtime|egress)(?:-[a-z0-9]+)*\.yml\z/
    abort("#{name}: use <product>-<component>[-<purpose>].yml or reusable-<action>-<target>.yml") unless name.match?(pattern)
    document.fetch("jobs").each_value do |job|
      reference = job["uses"]
      next unless reference&.start_with?("./.github/workflows/")
      target = File.expand_path(reference, root)
      abort("#{name}: missing reusable workflow #{reference}") unless files.include?(target)
      called = YAML.safe_load(File.read(target), aliases: true)
      abort("#{name}: #{reference} must support workflow_call") unless called.fetch("on").key?("workflow_call")
    end
  end
  puts "Workflow naming and reusable references are valid (#{files.length} files)."
' "$PROJECT_ROOT"
