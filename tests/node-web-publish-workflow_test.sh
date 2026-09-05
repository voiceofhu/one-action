#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ruby -ryaml -e '
  root = ARGV.fetch(0)
  server = YAML.load_file("#{root}/.github/workflows/node-server.yml")
  web = YAML.load_file("#{root}/.github/workflows/node-web.yml")
  abort "Server jobs" unless server.fetch("jobs").keys.sort == %w[deploy prepare publish]
  abort "Web jobs" unless web.fetch("jobs").keys.sort == %w[build deploy]
  [server, web].each do |workflow|
    abort "dispatch only" unless workflow.fetch("on").keys == ["workflow_dispatch"]
    deploy = workflow.fetch("jobs").fetch("deploy")
    abort "environment" unless deploy.fetch("environment").fetch("name") == "one-node-prod"
    abort "deployment race" unless deploy.fetch("concurrency").fetch("group") == "one-node-server-prod-deploy"
    workflow.fetch("jobs").each_value do |job|
      job.fetch("steps", []).each do |step|
        next unless step["run"]
        IO.popen(["bash", "-n"], "w") { |io| io.write(step["run"]) }
        abort "invalid workflow shell" unless $?.success?
      end
    end
  end
  repos = web.fetch("jobs").fetch("build").fetch("steps").map { |s| s.dig("with", "repository") }.compact
  abort "Web must only checkout Web source" unless repos == ["voiceofhu/one-node-web"]
  compose = YAML.load_file("#{root}/../one-node/backend/deploy/docker-compose.yml")
  service = compose.fetch("services").fetch("server")
  abort "persistent web mount" unless service.fetch("volumes") == ["./web:/app/web:ro"]
  abort "dynamic current path" unless service.fetch("environment").fetch("WEB_DIST_DIR") == "/app/web/current"
  release = File.read("#{root}/scripts/release/deploy-node-web-release.sh")
  abort "Web release depends on Server" if release.include?("ONE_NODE_SERVER") || release.include?("cargo ")
  abort "checks before dispatch" unless release.index(" lint") < release.index("dispatch-workflow.sh") && release.index(" build") < release.index("dispatch-workflow.sh")
  server_deploy = File.read("#{root}/scripts/deploy/deploy-node-server.sh")
  abort "Server must update Web" unless server_deploy.include?("docker cp") && server_deploy.include?("mv -Tf web/current.next web/current")
  abort "Server must restore Web on failure" unless server_deploy.include?("mv -Tf web/current.rollback web/current")
  abort "Do not require tar inside production image" if server_deploy.include?("--entrypoint tar")
  deploy = File.read("#{root}/scripts/deploy/deploy-node-web.sh")
  abort "Web changes Server" if deploy.match?(/docker|compose|systemctl/)
  abort "Web rollback" unless deploy.include?("trap rollback ERR") && deploy.include?("mv -Tf current.rollback current")
  abort "Web commit switch" unless deploy.include?("mv -Tf current.next current")
' "$PROJECT_ROOT"
printf '%s\n' 'Node Server/Web workflow contracts passed.'
