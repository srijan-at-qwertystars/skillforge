# terraform-aws-MODULE_NAME

Brief description of what this module creates and manages.

## Usage

```hcl
module "example" {
  source  = "git::https://github.com/org/terraform-aws-MODULE_NAME.git?ref=v1.0.0"

  name        = "my-resource"
  environment = "prod"

  tags = {
    Team = "platform"
  }
}
```

## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.6.0 |
| aws | ~> 5.0 |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| name | Name prefix for all resources | `string` | n/a | yes |
| environment | Deployment environment | `string` | `"dev"` | no |
| tags | Additional tags to apply | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| — | — |

## Examples

- [Complete](examples/complete) — Full example with all options

## Testing

```bash
# Run plan-only tests
terraform test

# Run all tests including apply
terraform test -filter=tests/integration.tftest.hcl
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Run `terraform fmt -recursive` and `terraform validate`
4. Submit a pull request

## License

Apache 2.0
