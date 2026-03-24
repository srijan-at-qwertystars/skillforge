# Example Terraform Test File (.tftest.hcl)
#
# Place in tests/ directory of your module.
# Run with: terraform test
#
# Documentation: https://developer.hashicorp.com/terraform/language/tests
#
# This file demonstrates all major terraform test features:
#   - Plan-only tests (fast, no infra cost)
#   - Variable validation tests (expect_failures)
#   - Apply tests (creates real resources)
#   - Module source overrides
#   - Run dependencies (referencing previous run outputs)

###############################################################################
# Global Variables — defaults for all runs in this file
###############################################################################

variables {
  name        = "tftest-example"
  environment = "dev"
  tags = {
    TestSuite = "terrafile"
    ManagedBy = "terraform-test"
  }
}

###############################################################################
# Variable Validation Tests
###############################################################################

run "rejects_empty_name" {
  command = plan

  variables {
    name = ""
  }

  expect_failures = [var.name]
}

run "rejects_invalid_environment" {
  command = plan

  variables {
    environment = "invalid"
  }

  expect_failures = [var.environment]
}

run "accepts_valid_environments" {
  command = plan

  variables {
    environment = "prod"
  }

  # No expect_failures — this should succeed
  assert {
    condition     = var.environment == "prod"
    error_message = "Environment should be prod."
  }
}

###############################################################################
# Plan Tests — validate resource configuration without creating anything
###############################################################################

run "plan_creates_expected_resources" {
  command = plan

  assert {
    condition     = var.name == "tftest-example"
    error_message = "Name variable should be set to test value."
  }

  # Add resource-specific assertions:
  # assert {
  #   condition     = aws_vpc.main.cidr_block == "10.0.0.0/16"
  #   error_message = "VPC CIDR block should be 10.0.0.0/16."
  # }
  #
  # assert {
  #   condition     = aws_vpc.main.enable_dns_hostnames == true
  #   error_message = "DNS hostnames should be enabled."
  # }
}

run "plan_tags_are_applied" {
  command = plan

  variables {
    tags = {
      Team       = "platform"
      CostCenter = "12345"
    }
  }

  # assert {
  #   condition     = aws_vpc.main.tags["Team"] == "platform"
  #   error_message = "Team tag should be applied."
  # }
}

###############################################################################
# Apply Tests — create real infrastructure and validate
# Uncomment when ready to test against a real provider.
###############################################################################

# run "apply_creates_resources" {
#   command = apply
#
#   assert {
#     condition     = output.id != ""
#     error_message = "Resource ID must not be empty after apply."
#   }
# }

# run "verify_applied_resource" {
#   command = plan
#
#   # Reference outputs from the previous apply run
#   # module {
#   #   source = "./tests/verify"
#   # }
#   #
#   # variables {
#   #   resource_id = run.apply_creates_resources.id
#   # }
# }

###############################################################################
# Module Override Test — test a child module in isolation
###############################################################################

# run "test_child_module" {
#   command = plan
#
#   module {
#     source = "./modules/security-group"
#   }
#
#   variables {
#     vpc_id = "vpc-test123"
#     name   = "test-sg"
#   }
#
#   assert {
#     condition     = aws_security_group.this.name == "test-sg"
#     error_message = "Security group name mismatch."
#   }
# }
