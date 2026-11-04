# Release runbook

## Flow
1. PR merged to `main` and CI is green (api tests, web build, full-stack smoke test).
2. Tag the commit: `git tag v1.4.0 && git push origin v1.4.0`.
3. The **Release** workflow builds `wealthwise-api` and `wealthwise-web` images and pushes them to GHCR with the version tag.
4. If the repository variable `OCTOPUS_URL` is set, the workflow creates an Octopus release and deploys it to **Staging**.
5. Promote to **Production** in Octopus after the manual approval step.

## One-time Octopus setup
1. Request the free license at octopus.com, base64 it into `.env` as `OCTOPUS_LICENSE_B64`, then `docker compose -f deploy/octopus/docker-compose.yml up -d` and open http://localhost:8081.
2. Create environments `Staging` and `Production` with a lifecycle that requires Staging first.
3. Create project `WealthWise` with a **Run a script** or **Deploy a container** step per image, and a manual intervention step before Production.
4. Add a GitHub Container Registry external feed.
5. Create an API key; in GitHub add repository variable `OCTOPUS_URL` and secrets `OCTOPUS_API_KEY`.

Octopus must be able to reach your deployment targets. On a laptop, use a Tentacle or an SSH target on another WSL distro or VM; GitHub-hosted runners cannot reach `localhost`, so for a pure-local run use `act` or a self-hosted runner in WSL.

## Rollback
Redeploy the previous release in Octopus. Database changes must be backward compatible for one release so rollback is safe.

## Smoke test after deploy
`GW=https://staging.example.com KEY=<key> bash scripts/smoke.sh`
