# spinup

## Overview

![High-level architecture](assets/high-level.png)

## Bootstrap Tiers

![Bootstrap tiers](assets/bootstrap-tiers.png)

## Terraform Templates

Terraform templates for provisioning VMs — just `.tf` files you clone and run. Built on official providers:

- **Azure** — [Azure/terraform quickstarts](https://github.com/azure/terraform/tree/master/quickstart) · [Linux VM quickstart](https://learn.microsoft.com/en-us/azure/virtual-machines/linux/quick-create-terraform)
- **AWS** — [aws-samples/aws-terraform-template](https://github.com/aws-samples/aws-terraform-template) · [terraform-aws-ec2-instance](https://github.com/terraform-aws-modules/terraform-aws-ec2-instance)

![Terraform templates](assets/terraform-templates.png)

## Quick Start

```bash
# Base tier (docker, lazydocker, aliases)
curl -sSL https://raw.githubusercontent.com/NicholasGoh/spinup/f257023eccf34c28162f134ff2df0bbe5451f3d2/bootstrap.sh | bash

# Dev tier (base + fd, ripgrep, lazygit)
curl -sSL https://raw.githubusercontent.com/NicholasGoh/spinup/f257023eccf34c28162f134ff2df0bbe5451f3d2/bootstrap.sh | bash -s -- --dev
```
