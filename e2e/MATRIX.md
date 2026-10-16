# Bitrix24–Asterisk parity E2E matrix

Target layout: **Market App on the vendor host**, **Connector + FreePBX on the
customer host**, linked manually in the Market App UI.

Run non-destructive checks with `./e2e/run.sh`. It validates this repo's
`docker-compose.yml` (FreePBX) and optionally probes Connector / Market App
via `E2E_CONNECTOR_URL` / `E2E_APP_URL`. Live call tests are skipped unless
`E2E_RUN_LIVE=1`, `E2E_LIVE_BITRIX=1`, and `E2E_LIVE_AMI=1` are set.

For each live scenario, record the Bitrix24 call ID, Connector `session_id`,
Asterisk `linkedid`, and the evidence specified below. Use a dedicated test
portal, extensions, and phone numbers.

| Scenario | Trigger | Expected parity evidence |
|---|---|---|
| Inbound, known caller | Call DID from CRM contact | Call Card opens; contact/deal is found; call is finalized once. |
| Inbound, unknown caller | Call DID from an unregistered number | Configured CRM create policy is applied; Call Card stays correlated to one `linkedid`. |
| Inbound missed | Ring target then do not answer | Bitrix status is missed; no answered duration; one completed activity. |
| Inbound busy | Call a busy extension | Bitrix status is busy; `DialStatus`/hangup cause is retained in Connector event history. |
| Inbound unavailable | Route to unavailable extension/trunk | Bitrix status is unavailable; no duplicate activity after CEL reconciliation. |
| Outbound, known caller | Bitrix click-to-call to CRM contact | AMI Originate succeeds; Call Card and completion attach to the contact/deal. |
| Outbound, unknown caller | Bitrix click-to-call to arbitrary number | Call begins and completes; configured unknown-number policy is honored. |
| Transfer | Blind and attended transfer during a call | One business call is preserved across legs; final result and recording use merged `linkedid`. |
| Queue | Inbound route through a queue | Agent answer and final status are correct; abandoned calls map to missed/unavailable policy. |
| Call Card/deal | Run known inbound and outbound cases | Card is visible during the call; existing deal is selected or policy creates/links it. |
| Recording link/file | Complete a recorded call | File exists in `shared_recordings`; public HTTPS recording link returns the expected audio without exposing other paths. |
| Timeman | Call a Bitrix user with time tracking enabled | Call events do not break Timeman state; resulting activity is visible to the user. |
| Restart/replay | Restart Connector during an active or just-ended call | AMI listener reconnects; pending outbox event is delivered exactly once; no duplicate Card/activity. |
| Multi-Asterisk | Configure a second AMI/CEL instance and place calls through both | Each call keeps its source Asterisk identity; no cross-instance `linkedid` collision or recording mix-up. |

## Live execution notes

1. Configure each Asterisk in Connector Admin with AMI host
   `host.docker.internal`, AMI port `5038`, and CEL MySQL host
   `host.docker.internal`, port `${FREEPBX_DB_PORT:-3307}` for this bundled
   FreePBX. For remote Asterisks, use their private address instead.
2. Complete the Market App and Connector setup wizards against the test portal.
3. Ensure public reverse proxies terminate TLS for the **vendor** Market App
   `BASE_URL` and the **customer** Connector `BASE_URL`; Bitrix24 must fetch
   recording links over HTTPS from the customer Connector.
4. Run the smoke gate, then execute the live matrix with test fixtures:

```bash
./e2e/run.sh
E2E_CONNECTOR_URL=https://connector.customer.example \
E2E_APP_URL=https://app.vendor.example \
E2E_RUN_LIVE=1 E2E_LIVE_BITRIX=1 E2E_LIVE_AMI=1 ./e2e/run.sh
```

Automated coverage in `bitrix24-asterisk-app/e2e/` (when `E2E_RUN_LIVE=1` and
`E2E_MUTATE_SETTINGS=1` for settings tests):

| Matrix row | Test module |
|---|---|
| Inbound missed / known | `test_10_inbound.py` |
| Outbound originate | `test_20_outbound.py` |
| Autodistribution /forward | `test_60_forward.py` |
| CRM gates / policies | `test_40_api_settings_crm.py` |
| Transfer (Call Card handoff) | `test_80_transfer_events.py` |
| Trunk DID autoreplacement | `test_81_trunk_replacement.py` |
| Recording URL on finish | `test_82_recording_smoke.py` |
| Security (/metrics, forward auth) | `test_70_security.py` |

Queue, AMI blind transfer, Timeman, restart/replay, and multi-Asterisk still
need manual fixtures or dedicated env vars (`E2E_QUEUE`, second AMI host).
