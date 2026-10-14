# C4 · The AI assistant is up, but not working — END state

"Ask AI Assistant" in the store admin returns a generated product description from the Foundry model deployment.

| | Begin state (fault) | End state (this folder) |
|---|---|---|
| ConfigMap `ai-service-configs`, `AZURE_OPENAI_DEPLOYMENT_NAME` | the retired deployment `store-assistant-gpt41` (doesn't exist) | the provisioned deployment `store-assistant` (model `gpt-6-luna`) |

Microsoft Entra workload identity (`USE_AZURE_AD: True`, no API keys, key auth disabled on the account), the
model deployment, identity, role assignment and federated credential are identical in both states.

How a participant gets here: [begin-challenge/challenges/c4-ai-assistant-up-but-not-working/SOLUTION.md](../../../begin-challenge/challenges/c4-ai-assistant-up-but-not-working/SOLUTION.md)

## Verify

```bash
scoring/verify.sh --context <cluster-name> --challenges c4        # bash
./scoring/verify.ps1 -Context <cluster-name> -Challenges c4       # PowerShell
```

Every check should report `PASS`.