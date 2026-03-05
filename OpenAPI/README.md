# OpenAPI Inputs

Place backend specs here:

- `OpenAPI/rest_openapi.json`
- `OpenAPI/ws_openapi.json`

Current workspace already contains both files and they can be used directly.

Then run:

```bash
./scripts/check_openapi_coverage.py --rest-spec OpenAPI/rest_openapi.json --ws-spec OpenAPI/ws_openapi.json
```

Child non-regression gate (baseline protection):

```bash
python3 scripts/check_child_openapi_baseline.py --rest-spec OpenAPI/rest_openapi.json --ws-spec OpenAPI/ws_openapi.json --min-rest 19 --min-ws 2
```

By default the script compares against:

- Child source: `Smart Oila Kids/SmartOilaKids`
- Parent source: `../Smart Oila Parent/Source`

Override parent source if needed:

```bash
./scripts/check_openapi_coverage.py --rest-spec OpenAPI/rest_openapi.json --ws-spec OpenAPI/ws_openapi.json --parent-source "/absolute/path/to/Smart Oila Parent/Source"
```
