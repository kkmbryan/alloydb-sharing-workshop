# Contributing

This repository is a **reference architecture and enablement resource** produced for an
AlloyDB operations workshop. It is intentionally read-optimised: every example is meant to
be understood in a workshop setting, then copied and adapted into the consuming team's own
infrastructure repository.

## Ground rules

1. **Never commit real values.** No project IDs, no CIDR ranges belonging to a real VPC, no
   KMS key resource names, no passwords. Use `terraform.tfvars.example` with obviously fake
   placeholders (`my-project-id`, `10.0.0.0/24`).
2. **Never commit Terraform state.** `.gitignore` blocks it; do not override. AlloyDB state
   contains the plaintext `initial_user` password.
3. **Examples must stand alone.** A reader should be able to `cd` into any directory under
   `terraform/examples/`, fill in `terraform.tfvars`, and run `terraform init && plan`
   without reading any other example.
4. **Explain the "why".** Every non-obvious argument should carry an inline comment. The
   audience is learning AlloyDB, not reviewing production code.

## Before you open a pull request

```bash
./scripts/validate.sh
```

This runs `terraform fmt -recursive -check` and `terraform init -backend=false` +
`terraform validate` against every module and example. CI runs the same script.

## Style

| Topic | Convention |
| --- | --- |
| Terraform files | `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf` |
| Variable naming | `snake_case`, always with a `description` and an explicit `type` |
| Required vs optional | Required variables have no `default`; optional ones always do |
| Resource naming | `${var.name_prefix}-<role>` so one config can be deployed many times |
| Comments | `#` for prose, placed above the block it explains |
| Docs | One topic per file under `docs/04-operations/`, linked from the root `README.md` |

## Keeping the content accurate

AlloyDB ships features quickly. Anything in this repo that states a hard number (machine
shapes, quotas, retention windows, metric names) should carry a link to the Google Cloud
documentation page it came from, so a future reader can re-verify it. If you update a fact,
update the link and the "last verified" date in the page footer.
