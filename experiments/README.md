# Experiments

End-to-end validation runs for the k3d-lab setup. Each experiment is self-contained:

- `README.md` — goal, constraints, method, and the recorded **outcome**.
- `journal/` — dated logs of the actual process: commands run, problems hit, and
  the fixes applied. The journal is the running narrative; the README's Outcome
  section is the distilled conclusion.

| # | Experiment | Status | Access path tested |
|---|------------|--------|--------------------|
| 01 | [no-tailscale](01-no-tailscale/) | ✅ PASS | Local / LAN via Cilium LB IPs |
| 02 | [with-tailscale](02-with-tailscale/) | ⏸ paused (needs route approval) | Remote via Tailscale/Headscale subnet route |
| 03 | [remote-route-approval](03-remote-route-approval/) | 📐 design + tooling (needs API key) | Approve routes via Headscale API, no host access |

Experiments 01–02 deploy the same workload: [`test/echo`](../test/echo) (`echo.home.lan`).
Exp 03 unblocks Exp 02 by enabling remote route approval (`tailscale/approve-route.sh`).
